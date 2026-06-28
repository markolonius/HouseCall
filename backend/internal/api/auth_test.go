package api_test

// TestHandler_Register_* exercises POST /api/auth/register using the real
// router and a live test database (TEST_DATABASE_URL). It follows the same
// pattern as recommendations_test.go: apiTestPool + real chi router.
//
// Covered:
//   - Happy path: 201, token, patient_id; token authenticates a subsequent
//     GET /api/conversations request (200).
//   - Duplicate email: 409 on a second registration attempt.

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/api"
	"github.com/markolonius/housecall/backend/internal/store"
)

// TestHandler_Register_HappyPath verifies that a new patient can register and
// that the returned token grants access to an authenticated endpoint.
func TestHandler_Register_HappyPath(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "register-test-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	// --- register ---
	body, _ := json.Marshal(map[string]string{
		"tenant_id": tenant.ID.String(),
		"email":     "new@register.test",
		"password":  "hunter2-but-longer",
	})
	req := httptest.NewRequest(http.MethodPost, "/api/auth/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)

	if rw.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rw.Code, rw.Body.String())
	}

	var resp struct {
		Token     string `json:"token"`
		ActorType string `json:"actor_type"`
		ActorID   string `json:"actor_id"`
		PatientID string `json:"patient_id"`
	}
	if err := json.NewDecoder(rw.Body).Decode(&resp); err != nil {
		t.Fatalf("decode register response: %v", err)
	}
	if resp.Token == "" {
		t.Fatal("expected non-empty token")
	}
	if resp.PatientID == "" {
		t.Fatal("expected non-empty patient_id")
	}
	if resp.ActorID != resp.PatientID {
		t.Errorf("actor_id %q != patient_id %q", resp.ActorID, resp.PatientID)
	}
	if resp.ActorType != "patient" {
		t.Errorf("expected actor_type=patient, got %q", resp.ActorType)
	}

	// --- confirm the returned token authenticates GET /api/conversations ---
	authReq := httptest.NewRequest(http.MethodGet, "/api/conversations", nil)
	authReq.Header.Set("Authorization", "Bearer "+resp.Token)
	authRW := httptest.NewRecorder()
	r.ServeHTTP(authRW, authReq)

	if authRW.Code != http.StatusOK {
		t.Errorf("authenticated GET /api/conversations: expected 200, got %d: %s",
			authRW.Code, authRW.Body.String())
	}
}

// TestHandler_Register_DuplicateEmail verifies that registering the same email
// twice within a tenant returns 409 and does not create a second patient row.
func TestHandler_Register_DuplicateEmail(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "register-dup-test-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	registerBody := func() *bytes.Reader {
		b, _ := json.Marshal(map[string]string{
			"tenant_id": tenant.ID.String(),
			"email":     "dup@register.test",
			"password":  "password-does-not-matter",
		})
		return bytes.NewReader(b)
	}

	// First registration — must succeed.
	req1 := httptest.NewRequest(http.MethodPost, "/api/auth/register", registerBody())
	req1.Header.Set("Content-Type", "application/json")
	rw1 := httptest.NewRecorder()
	r.ServeHTTP(rw1, req1)
	if rw1.Code != http.StatusCreated {
		t.Fatalf("first register: expected 201, got %d: %s", rw1.Code, rw1.Body.String())
	}

	// Second registration with the same email — must be rejected.
	req2 := httptest.NewRequest(http.MethodPost, "/api/auth/register", registerBody())
	req2.Header.Set("Content-Type", "application/json")
	rw2 := httptest.NewRecorder()
	r.ServeHTTP(rw2, req2)
	if rw2.Code != http.StatusConflict {
		t.Errorf("duplicate register: expected 409, got %d: %s", rw2.Code, rw2.Body.String())
	}
}
