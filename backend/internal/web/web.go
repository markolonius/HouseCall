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
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/review"
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
	// templates is a per-page template set keyed by page name (e.g. "login",
	// "panel", "queue"). Each value is the layout cloned with only that page's
	// block definitions, so {{define "content"}} in different page files do not
	// collide inside a single shared *template.Template.
	templates map[string]*template.Template

	// test-injectable interfaces (nil in production).
	storeQ interface {
		GetPhysicianByEmail(ctx context.Context, tenant store.TenantID, email string) (store.Physician, error)
		ListPatientsByPhysician(ctx context.Context, tenant store.TenantID, physicianID uuid.UUID) ([]store.Patient, error)
		ListRecommendationsByPhysician(ctx context.Context, tenant store.TenantID, physicianID uuid.UUID, state string) ([]store.Recommendation, error)

		// Review action methods (task 5.3). These satisfy review.Store so the
		// handler can pass storeQ directly to review.Execute in tests.
		GetRecommendationForPhysician(ctx context.Context, tenant store.TenantID, physicianID, recID uuid.UUID) (store.Recommendation, error)
		GetPhysician(ctx context.Context, tenant store.TenantID, id uuid.UUID) (store.Physician, error)
		GetPatient(ctx context.Context, tenant store.TenantID, id uuid.UUID) (store.Patient, error)
		CreateAuditEvent(ctx context.Context, tenant store.TenantID, e store.AuditEvent) (store.AuditEvent, error)
		TxnW(ctx context.Context, fn func(store.TxWriter) error) error
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

// pageTemplates maps each page name to the set of template files it needs.
// The layout is always included first so {{block}} definitions in the page
// file can override the layout's default (empty) blocks. Each page gets its
// own template set so {{define "content"}} in different page files do not
// overwrite each other in a shared set.
var pageTemplates = map[string][]string{
	"login": {"templates/layout.html", "templates/login.html"},
	"panel": {"templates/layout.html", "templates/panel.html"},
	"queue": {"templates/layout.html", "templates/queue.html"},
}

// parseTemplates builds a per-page template set from the embedded FS.
func parseTemplates() (map[string]*template.Template, error) {
	sets := make(map[string]*template.Template, len(pageTemplates))
	for name, files := range pageTemplates {
		t, err := template.ParseFS(templateFS, files...)
		if err != nil {
			return nil, err
		}
		sets[name] = t
	}
	return sets, nil
}

// tmpl returns the template set for the named page, or nil if not found.
func (h *Handler) tmpl(name string) *template.Template {
	return h.templates[name]
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
			r.Get("/", func(w http.ResponseWriter, req *http.Request) {
				http.Redirect(w, req, "/web/queue", http.StatusSeeOther)
			})
			r.Get("/panel", h.handlePanel)
			r.Get("/queue", h.handleQueue)
			r.Post("/recommendations/{id}/review", h.handleReview)
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

// listPatientsByPhysician routes to the test-injectable interface if set,
// otherwise to the concrete store.
func (h *Handler) listPatientsByPhysician(ctx context.Context, tenant store.TenantID, physicianID uuid.UUID) ([]store.Patient, error) {
	if h.storeQ != nil {
		return h.storeQ.ListPatientsByPhysician(ctx, tenant, physicianID)
	}
	return h.store.ListPatientsByPhysician(ctx, tenant, physicianID)
}

// listRecommendationsByPhysician routes to the test-injectable interface if set,
// otherwise to the concrete store.
func (h *Handler) listRecommendationsByPhysician(ctx context.Context, tenant store.TenantID, physicianID uuid.UUID, state string) ([]store.Recommendation, error) {
	if h.storeQ != nil {
		return h.storeQ.ListRecommendationsByPhysician(ctx, tenant, physicianID, state)
	}
	return h.store.ListRecommendationsByPhysician(ctx, tenant, physicianID, state)
}

// reviewStore returns the review.Store implementation to use. In tests storeQ
// satisfies review.Store directly; in production the concrete *store.Store does.
func (h *Handler) reviewStore() review.Store {
	if h.storeQ != nil {
		return h.storeQ
	}
	return h.store
}

// ---- panel handler ----

type panelPageData struct {
	Patients []store.Patient
}

func (h *Handler) handlePanel(w http.ResponseWriter, r *http.Request) {
	claims, ok := webClaimsFromCtx(r.Context())
	if !ok {
		// requireWebAuth already guarantees this; defensive check.
		http.Redirect(w, r, "/web/login", http.StatusSeeOther)
		return
	}

	patients, err := h.listPatientsByPhysician(r.Context(), claims.TenantID, claims.ActorID)
	if err != nil {
		log.Printf("web: panel store error: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.writeAudit(r.Context(), claims.TenantID, "physician", &claims.ActorID, "web.panel.viewed", map[string]any{
		"actor_id": claims.ActorID.String(),
	})

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := h.tmpl("panel").ExecuteTemplate(w, "layout", panelPageData{Patients: patients}); err != nil {
		log.Printf("web: render panel template: %v", err)
	}
}

// ---- queue handler ----

type queuePageData struct {
	Recommendations []store.Recommendation
	// Error is shown as a flash banner when a review action fails (e.g.
	// unlicensed-state rejection). Empty string means no error.
	Error string
}

func (h *Handler) handleQueue(w http.ResponseWriter, r *http.Request) {
	claims, ok := webClaimsFromCtx(r.Context())
	if !ok {
		// requireWebAuth already guarantees this; defensive check.
		http.Redirect(w, r, "/web/login", http.StatusSeeOther)
		return
	}

	recs, err := h.listRecommendationsByPhysician(r.Context(), claims.TenantID, claims.ActorID, "PENDING_REVIEW")
	if err != nil {
		log.Printf("web: queue store error: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.writeAudit(r.Context(), claims.TenantID, "physician", &claims.ActorID, "web.queue.viewed", map[string]any{
		"actor_id": claims.ActorID.String(),
	})

	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	if err := h.tmpl("queue").ExecuteTemplate(w, "layout", queuePageData{Recommendations: recs}); err != nil {
		log.Printf("web: render queue template: %v", err)
	}
}

// ---- review handler (task 5.3) ----

// handleReview processes POST /web/recommendations/{id}/review.
// It accepts application/x-www-form-urlencoded with fields:
//   - action: "approve" | "reject" | "modify"
//   - final_content: required for "modify"; accepted (but not required) for "approve"
//
// On success it redirects to /web/queue (303).
// On ErrUnlicensedState it renders the queue with an error banner (state is NOT
// mutated; the rejection audit event was already written by review.Execute).
// On a care-relationship / access failure it returns 403/404.
func (h *Handler) handleReview(w http.ResponseWriter, r *http.Request) {
	claims, ok := webClaimsFromCtx(r.Context())
	if !ok {
		http.Redirect(w, r, "/web/login", http.StatusSeeOther)
		return
	}

	if err := r.ParseForm(); err != nil {
		http.Error(w, "invalid form submission", http.StatusBadRequest)
		return
	}

	recIDStr := chi.URLParam(r, "id")
	recID, err := uuid.Parse(recIDStr)
	if err != nil {
		http.Error(w, "invalid recommendation id", http.StatusBadRequest)
		return
	}

	action := r.FormValue("action")
	finalContent := r.FormValue("final_content")

	// modify requires a non-empty final_content.
	if action == domain.ActionModify && finalContent == "" {
		http.Error(w, "final_content required for modify", http.StatusBadRequest)
		return
	}

	ctx := r.Context()
	result, err := review.Execute(ctx, h.reviewStore(), claims.TenantID, claims.ActorID, recID, action, finalContent)

	if errors.Is(err, store.ErrNotFound) {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if errors.Is(err, domain.ErrUnlicensedState) {
		// Render the queue with an error banner. State was NOT mutated; the audit
		// event was already written by review.Execute.
		h.renderQueueWithError(w, r, claims, "Action rejected: you are not licensed in the patient's state.")
		return
	}
	if errors.Is(err, domain.ErrInvalidTransition) {
		http.Error(w, "invalid transition", http.StatusUnprocessableEntity)
		return
	}
	if err != nil {
		log.Printf("web: review recommendation %s: %v", recIDStr, err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}

	h.writeAudit(ctx, claims.TenantID, "physician", &claims.ActorID, "web.recommendation.reviewed", map[string]any{
		"actor_id":          claims.ActorID.String(),
		"recommendation_id": result.RecommendationID.String(),
		"action":            action,
		"new_state":         result.FinalState,
	})

	// Redirect back to the queue (PRG pattern: prevents double-submit on reload).
	http.Redirect(w, r, "/web/queue", http.StatusSeeOther)
}

// renderQueueWithError re-fetches the queue and renders it with an error banner.
func (h *Handler) renderQueueWithError(w http.ResponseWriter, r *http.Request, claims webClaims, errMsg string) {
	recs, err := h.listRecommendationsByPhysician(r.Context(), claims.TenantID, claims.ActorID, "PENDING_REVIEW")
	if err != nil {
		log.Printf("web: queue store error on error render: %v", err)
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(http.StatusForbidden)
	if err := h.tmpl("queue").ExecuteTemplate(w, "layout", queuePageData{
		Recommendations: recs,
		Error:           errMsg,
	}); err != nil {
		log.Printf("web: render queue error template: %v", err)
	}
}

// ---- template renderer ----

func (h *Handler) renderLogin(w http.ResponseWriter, status int, errMsg string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	if err := h.tmpl("login").ExecuteTemplate(w, "layout", loginPageData{Error: errMsg}); err != nil {
		log.Printf("web: render login template: %v", err)
	}
}
