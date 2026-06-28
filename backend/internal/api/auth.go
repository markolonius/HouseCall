package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/store"
	"golang.org/x/crypto/bcrypt"
)

// bcryptCost is the work factor for all password hashing in the API. Must
// match the value used in cmd/seed so seeded accounts are compatible.
const bcryptCost = 12

type loginRequest struct {
	TenantID string `json:"tenant_id"`
	Email    string `json:"email"`
	Password string `json:"password"`
}

type loginResponse struct {
	Token     string `json:"token"`
	ActorType string `json:"actor_type"`
	ActorID   string `json:"actor_id"`
}

// registerResponse is the 201 body returned by POST /api/auth/register.
// It mirrors loginResponse and adds patient_id as the canonical patient
// identity (equal to actor_id) so the iOS client can key local storage on
// the server-assigned UUID from the first request.
type registerResponse struct {
	Token     string `json:"token"`
	ActorType string `json:"actor_type"`
	ActorID   string `json:"actor_id"`
	PatientID string `json:"patient_id"`
}

func (rt *Router) handleLogin(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if req.TenantID == "" || req.Email == "" || req.Password == "" {
		http.Error(w, "tenant_id, email, and password are required", http.StatusBadRequest)
		return
	}
	tid, err := uuid.Parse(req.TenantID)
	if err != nil {
		http.Error(w, "invalid tenant_id", http.StatusBadRequest)
		return
	}
	tenant := store.TenantID(tid)
	ctx := r.Context()

	// Try patient first, then physician. Both fail with the same opaque
	// "invalid credentials" message to prevent account enumeration.
	var claims AuthClaims
	if patient, err := rt.store.GetPatientByEmail(ctx, tenant, req.Email); err == nil {
		if bcrypt.CompareHashAndPassword([]byte(patient.PasswordHash), []byte(req.Password)) != nil {
			http.Error(w, "invalid credentials", http.StatusUnauthorized)
			return
		}
		claims = AuthClaims{TenantID: tenant, ActorID: patient.ID, ActorType: "patient"}
	} else if errors.Is(err, store.ErrNotFound) {
		physician, err := rt.store.GetPhysicianByEmail(ctx, tenant, req.Email)
		if err != nil {
			http.Error(w, "invalid credentials", http.StatusUnauthorized)
			return
		}
		if bcrypt.CompareHashAndPassword([]byte(physician.PasswordHash), []byte(req.Password)) != nil {
			http.Error(w, "invalid credentials", http.StatusUnauthorized)
			return
		}
		claims = AuthClaims{TenantID: tenant, ActorID: physician.ID, ActorType: "physician"}
	} else {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	token, err := issueToken(rt.secret, claims)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	rt.audit.Write(ctx, tenant, claims.ActorType, &claims.ActorID, "auth.login", map[string]any{
		"actor_id": claims.ActorID.String(),
	})

	writeJSON(w, http.StatusOK, loginResponse{
		Token:     token,
		ActorType: claims.ActorType,
		ActorID:   claims.ActorID.String(),
	})
}

// handleRegister handles POST /api/auth/register.
//
// Request body: {"tenant_id": "<uuid>", "email": "<email>", "password": "<plaintext>"}
//
// The patients table requires full_name and state (both NOT NULL). Those fields
// are not collected at registration; MVP safe defaults are used:
//   - full_name: "" (empty — patient may update later)
//   - state:     "--" (sentinel meaning "not provided"; valid char(2))
func (rt *Router) handleRegister(w http.ResponseWriter, r *http.Request) {
	var req loginRequest // same {tenant_id, email, password} shape as login
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if req.TenantID == "" || req.Email == "" || req.Password == "" {
		http.Error(w, "tenant_id, email, and password are required", http.StatusBadRequest)
		return
	}
	tid, err := uuid.Parse(req.TenantID)
	if err != nil {
		http.Error(w, "invalid tenant_id", http.StatusBadRequest)
		return
	}
	tenant := store.TenantID(tid)
	ctx := r.Context()

	// Reject duplicate email within the same tenant (409 Conflict).
	if _, err := rt.store.GetPatientByEmail(ctx, tenant, req.Email); err == nil {
		http.Error(w, "email already registered", http.StatusConflict)
		return
	} else if !errors.Is(err, store.ErrNotFound) {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	hash, err := bcrypt.GenerateFromPassword([]byte(req.Password), bcryptCost)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	patient, err := rt.store.CreatePatient(ctx, tenant, store.Patient{
		Email:        req.Email,
		PasswordHash: string(hash),
		// full_name and state are NOT NULL in the schema but are not collected
		// at registration (MVP). Safe defaults — neither is PHI and both can
		// be updated later via a profile endpoint.
		FullName: "",
		State:    "--",
	})
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	claims := AuthClaims{TenantID: tenant, ActorID: patient.ID, ActorType: "patient"}
	token, err := issueToken(rt.secret, claims)
	if err != nil {
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	// Audit: identifiers only — never the password or any PHI.
	rt.audit.Write(ctx, tenant, "patient", &patient.ID, "patient.registered", map[string]any{
		"patient_id": patient.ID.String(),
	})

	writeJSON(w, http.StatusCreated, registerResponse{
		Token:     token,
		ActorType: "patient",
		ActorID:   patient.ID.String(),
		PatientID: patient.ID.String(),
	})
}

// requireAuth validates the Bearer JWT and injects AuthClaims into the
// request context. Cognito-issued OIDC tokens plug in here (JWKS verifier
// swap) without changing any downstream handler.
func (rt *Router) requireAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		if token == "" {
			http.Error(w, "missing authorization", http.StatusUnauthorized)
			return
		}
		rc, err := verifyToken(rt.secret, token)
		if err != nil {
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}
		tid, err := uuid.Parse(rc.TenantID)
		if err != nil {
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}
		actorID, err := uuid.Parse(rc.ActorID)
		if err != nil {
			http.Error(w, "invalid token", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r.WithContext(withClaims(r.Context(), AuthClaims{
			TenantID:  store.TenantID(tid),
			ActorID:   actorID,
			ActorType: rc.ActorType,
		})))
	})
}

func bearerToken(r *http.Request) string {
	h := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(h, prefix) {
		return ""
	}
	return strings.TrimPrefix(h, prefix)
}
