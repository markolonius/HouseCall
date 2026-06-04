// Package web implements the server-rendered physician web application.
// Routes are mounted under a /web prefix by the caller (cmd/server) so they
// remain cleanly separated from the JSON API handlers under /api.
//
// Authentication: a form-based login POST issues the same HMAC-HS256 JWT that
// the Core API /auth/login endpoint issues, then wraps it in a session cookie
// (HttpOnly, Secure, SameSite=Lax). The requireWebAuth middleware reads the
// cookie, verifies the JWT via the shared verifyToken logic, and rejects
// non-physician actors with a redirect to the login form.
//
// HIPAA notes:
//   - The JWT value is never logged; only the actor_id is used in audit metadata.
//   - Every data read is tenant-scoped: tenant_id comes from the verified JWT,
//     never from request params.
//   - Session cookie is HttpOnly + Secure + SameSite=Lax.
package web

import (
	"context"
	"embed"
	"errors"
	"html/template"
	"log"
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/audit"
	"github.com/markolonius/housecall/backend/internal/store"
	"golang.org/x/crypto/bcrypt"
)

//go:embed templates/*.html
var templateFS embed.FS

const sessionCookieName = "hc_session"

// Handler holds the shared dependencies for the physician web app.
//
// The storeQ and auditQ fields allow tests (via NewWithQuerier in export_test.go)
// to inject fakes without a real database. Production code (New) leaves those
// nil and falls back to the concrete store/audit fields.
type Handler struct {
	store     *store.Store
	secret    []byte
	audit     *audit.Writer
	templates *template.Template

	// test-injectable interfaces (nil in production).
	storeQ interface {
		GetPhysicianByEmail(ctx context.Context, tenant store.TenantID, email string) (store.Physician, error)
	}
	auditQ interface {
		Write(ctx context.Context, tenant store.TenantID, actorType string, actorID *uuid.UUID, eventType string, metadata map[string]any)
	}
}

// New constructs a Handler for production use. secret is the HMAC-SHA256
// signing key shared with the Core API. aw is the shared audit.Writer.
func New(s *store.Store, secret []byte, aw *audit.Writer) (*Handler, error) {
	tmpl, err := parseTemplates()
	if err != nil {
		return nil, err
	}
	return &Handler{
		store:     s,
		secret:    secret,
		audit:     aw,
		templates: tmpl,
	}, nil
}

// parseTemplates parses all html/template files embedded in the templates/ dir.
func parseTemplates() (*template.Template, error) {
	return template.ParseFS(templateFS, "templates/*.html")
}

// Mount registers all physician web app routes on r under a /web prefix.
// The routes are separate from the JSON API handlers (/api) on the same chi
// router.
func (h *Handler) Mount(r chi.Router) {
	r.Route("/web", func(r chi.Router) {
		// Unauthenticated routes.
		r.Get("/login", h.handleLoginForm)
		r.Post("/login", h.handleLoginSubmit)

		// Authenticated, physician-only routes.
		r.Group(func(r chi.Router) {
			r.Use(h.requireWebAuth)
			// Root redirect; 5.2/5.3 will add real pages here.
			r.Get("/", func(w http.ResponseWriter, req *http.Request) {
				http.Redirect(w, req, "/web/queue", http.StatusSeeOther)
			})
		})
	})
}

// ---- login form ----

type loginPageData struct {
	Error string
}

func (h *Handler) handleLoginForm(w http.ResponseWriter, r *http.Request) {
	h.renderLogin(w, http.StatusOK, "")
}

func (h *Handler) handleLoginSubmit(w http.ResponseWriter, r *http.Request) {
	if err := r.ParseForm(); err != nil {
		h.renderLogin(w, http.StatusBadRequest, "invalid form submission")
		return
	}

	tenantRaw := r.FormValue("tenant_id")
	email := r.FormValue("email")
	password := r.FormValue("password")

	if tenantRaw == "" || email == "" || password == "" {
		h.renderLogin(w, http.StatusBadRequest, "all fields are required")
		return
	}

	tid, err := uuid.Parse(tenantRaw)
	if err != nil {
		h.renderLogin(w, http.StatusBadRequest, "invalid tenant")
		return
	}
	tenant := store.TenantID(tid)
	ctx := r.Context()

	// Look up the physician. Only physicians may log in to the web app.
	physician, err := h.getPhysicianByEmail(ctx, tenant, email)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			// Return the same opaque message as the Core API to prevent
			// account enumeration (consistent with api/auth.go).
			h.renderLogin(w, http.StatusUnauthorized, "invalid credentials")
			return
		}
		log.Printf("web: login store error: %v", err)
		h.renderLogin(w, http.StatusInternalServerError, "internal error, please try again")
		return
	}

	if bcrypt.CompareHashAndPassword([]byte(physician.PasswordHash), []byte(password)) != nil {
		h.renderLogin(w, http.StatusUnauthorized, "invalid credentials")
		return
	}

	// Issue a JWT with the same claims shape the Core API uses.
	claims := webClaims{
		TenantID:  tenant,
		ActorID:   physician.ID,
		ActorType: "physician",
	}
	token, err := issueWebToken(h.secret, claims)
	if err != nil {
		log.Printf("web: token issue error: %v", err)
		h.renderLogin(w, http.StatusInternalServerError, "internal error, please try again")
		return
	}

	// Wrap the JWT in an HttpOnly session cookie. The JWT value itself is
	// never written to logs; the audit record carries only the actor_id.
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookieName,
		Value:    token,
		Path:     "/web",
		MaxAge:   int(sessionTTL.Seconds()),
		HttpOnly: true,
		Secure:   true,
		SameSite: http.SameSiteLaxMode,
	})

	h.writeAudit(ctx, tenant, "physician", &physician.ID, "web.auth.login", map[string]any{
		"actor_id": physician.ID.String(),
	})

	http.Redirect(w, r, "/web/queue", http.StatusSeeOther)
}

// ---- middleware ----

// webClaimsContextKey is the context key for the physician's verified claims.
type webClaimsContextKey struct{}

// requireWebAuth validates the session cookie, verifies the embedded JWT, and
// rejects non-physician actors. On failure it redirects to the login form
// (never returning a JSON error — this is a browser-facing app).
func (h *Handler) requireWebAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		cookie, err := r.Cookie(sessionCookieName)
		if err != nil {
			http.Redirect(w, r, "/web/login", http.StatusSeeOther)
			return
		}

		rc, err := verifyWebToken(h.secret, cookie.Value)
		if err != nil {
			// Clear the stale cookie before redirecting.
			http.SetCookie(w, &http.Cookie{
				Name:     sessionCookieName,
				Value:    "",
				Path:     "/web",
				MaxAge:   -1,
				HttpOnly: true,
				Secure:   true,
				SameSite: http.SameSiteLaxMode,
			})
			http.Redirect(w, r, "/web/login", http.StatusSeeOther)
			return
		}

		// Physician-only gate. Patients authenticated against the Core API
		// cannot access the web app.
		if rc.ActorType != "physician" {
			http.Redirect(w, r, "/web/login", http.StatusSeeOther)
			return
		}

		tid, err := uuid.Parse(rc.TenantID)
		if err != nil {
			http.Redirect(w, r, "/web/login", http.StatusSeeOther)
			return
		}
		actorID, err := uuid.Parse(rc.ActorID)
		if err != nil {
			http.Redirect(w, r, "/web/login", http.StatusSeeOther)
			return
		}

		c := webClaims{
			TenantID:  store.TenantID(tid),
			ActorID:   actorID,
			ActorType: rc.ActorType,
		}
		next.ServeHTTP(w, r.WithContext(withWebClaims(r.Context(), c)))
	})
}

// webClaimsFromCtx retrieves the verified physician claims from a request
// context populated by requireWebAuth.
func webClaimsFromCtx(ctx context.Context) (webClaims, bool) {
	c, ok := ctx.Value(webClaimsContextKey{}).(webClaims)
	return c, ok
}

func withWebClaims(ctx context.Context, c webClaims) context.Context {
	return context.WithValue(ctx, webClaimsContextKey{}, c)
}

// ---- store / audit dispatch (production vs test) ----

// getPhysicianByEmail routes to the test-injectable interface if set,
// otherwise to the concrete store.
func (h *Handler) getPhysicianByEmail(ctx context.Context, tenant store.TenantID, email string) (store.Physician, error) {
	if h.storeQ != nil {
		return h.storeQ.GetPhysicianByEmail(ctx, tenant, email)
	}
	return h.store.GetPhysicianByEmail(ctx, tenant, email)
}

// writeAudit routes to the test-injectable audit interface if set,
// otherwise to the concrete audit.Writer.
func (h *Handler) writeAudit(ctx context.Context, tenant store.TenantID, actorType string, actorID *uuid.UUID, eventType string, metadata map[string]any) {
	if h.auditQ != nil {
		h.auditQ.Write(ctx, tenant, actorType, actorID, eventType, metadata)
		return
	}
	h.audit.Write(ctx, tenant, actorType, actorID, eventType, metadata)
}

// ---- template renderer ----

func (h *Handler) renderLogin(w http.ResponseWriter, status int, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := h.templates.ExecuteTemplate(w, "layout", loginPageData{Error: errMsg}); err != nil {
		log.Printf("web: render login template: %v", err)
	}
}
