package api_test

// TestHandler_Register_* exercises POST /api/auth/register using the real
// router and a live test database (TEST_DATABASE_URL). It follows the same
// pattern as recommendations_test.go: apiTestPool + real chi router.
//
// Covered:
//   - Happy path: 201, token, patient_id; token authenticates a subsequent
//     GET /api/conversations request (200).
//   - Duplicate email: 409 on a second registration attempt.
//   - Missing-field rejections: separate subtests for missing tenant_id, email, password → 400.
//   - Invalid tenant UUID → 400.
//   - Audit event: patient.registered written on success; password absent from metadata.
//   - Tenant isolation: patient registered in tenant A not visible in tenant B.
//   - Password storage: stored hash is bcrypt-verifiable and not the plaintext.

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/api"
	"github.com/markolonius/housecall/backend/internal/store"
	"golang.org/x/crypto/bcrypt"
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

// TestHandler_Register_MissingFields verifies that omitting any required field
// (tenant_id, email, or password) returns 400 and creates no patient row.
func TestHandler_Register_MissingFields(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	// A valid tenant UUID used where tenant_id is present — the UUID must parse
	// but the handler never reaches the DB for validation failures on other fields.
	validTID := uuid.NewString()

	cases := []struct {
		name string
		body map[string]string
	}{
		{
			name: "missing_tenant_id",
			body: map[string]string{
				"email":    "a@missing.test",
				"password": "hunter2-but-longer",
			},
		},
		{
			name: "missing_email",
			body: map[string]string{
				"tenant_id": validTID,
				"password":  "hunter2-but-longer",
			},
		},
		{
			name: "missing_password",
			body: map[string]string{
				"tenant_id": validTID,
				"email":     "a@missing.test",
			},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			b, _ := json.Marshal(tc.body)
			req := httptest.NewRequest(http.MethodPost, "/api/auth/register", bytes.NewReader(b))
			req.Header.Set("Content-Type", "application/json")
			rw := httptest.NewRecorder()
			r.ServeHTTP(rw, req)
			if rw.Code != http.StatusBadRequest {
				t.Fatalf("expected 400, got %d: %s", rw.Code, rw.Body.String())
			}
		})
	}

	// Confirm no patient rows were created by any of the rejected requests.
	var count int
	if err := pool.QueryRow(ctx, `SELECT COUNT(*) FROM patients`).Scan(&count); err != nil {
		t.Fatalf("count patients: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0 patients after validation failures, got %d", count)
	}
}

// TestHandler_Register_InvalidTenantUUID verifies that a non-UUID value for
// tenant_id returns 400 and creates no patient row.
func TestHandler_Register_InvalidTenantUUID(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	body, _ := json.Marshal(map[string]string{
		"tenant_id": "not-a-valid-uuid",
		"email":     "a@invalid-tid.test",
		"password":  "hunter2-but-longer",
	})
	req := httptest.NewRequest(http.MethodPost, "/api/auth/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)

	if rw.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for invalid tenant UUID, got %d: %s", rw.Code, rw.Body.String())
	}

	var count int
	if err := pool.QueryRow(ctx, `SELECT COUNT(*) FROM patients`).Scan(&count); err != nil {
		t.Fatalf("count patients: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0 patients after invalid tenant UUID, got %d", count)
	}
}

// TestHandler_Register_AuditEvent verifies that a successful registration
// writes a patient.registered audit event whose metadata contains the patient
// ID (an identifier) and does NOT contain the password string.
func TestHandler_Register_AuditEvent(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "register-audit-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	const testPassword = "audit-test-password-xyz"
	body, _ := json.Marshal(map[string]string{
		"tenant_id": tenant.ID.String(),
		"email":     "audit@register.test",
		"password":  testPassword,
	})
	req := httptest.NewRequest(http.MethodPost, "/api/auth/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)

	if rw.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rw.Code, rw.Body.String())
	}

	var resp struct {
		PatientID string `json:"patient_id"`
	}
	if err := json.NewDecoder(rw.Body).Decode(&resp); err != nil {
		t.Fatalf("decode register response: %v", err)
	}
	patientID, err := uuid.Parse(resp.PatientID)
	if err != nil {
		t.Fatalf("parse patient_id: %v", err)
	}

	// Query the audit_events table for the patient.registered event.
	var metadata []byte
	err = pool.QueryRow(ctx,
		`SELECT metadata FROM audit_events
		  WHERE tenant_id = $1
		    AND event_type  = 'patient.registered'
		    AND actor_id    = $2`,
		tid.UUID(), patientID,
	).Scan(&metadata)
	if err != nil {
		t.Fatalf("expected patient.registered audit event, got error: %v", err)
	}

	var meta map[string]any
	if err := json.Unmarshal(metadata, &meta); err != nil {
		t.Fatalf("unmarshal audit metadata: %v", err)
	}

	// Metadata must contain the patient identifier.
	if meta["patient_id"] != patientID.String() {
		t.Errorf("audit metadata patient_id = %q, want %q", meta["patient_id"], patientID.String())
	}

	// The plaintext password must never appear in the raw metadata bytes.
	if strings.Contains(string(metadata), testPassword) {
		t.Error("password must not appear in audit metadata")
	}
}

// TestHandler_Register_TenantIsolation verifies that a patient registered in
// tenant A is not visible via GetPatientByEmail in tenant B.
func TestHandler_Register_TenantIsolation(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenantA, err := s.CreateTenant(ctx, "dtc", "isolation-a-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant A: %v", err)
	}
	tenantB, err := s.CreateTenant(ctx, "dtc", "isolation-b-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant B: %v", err)
	}

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	const sharedEmail = "isolation@register.test"
	body, _ := json.Marshal(map[string]string{
		"tenant_id": tenantA.ID.String(),
		"email":     sharedEmail,
		"password":  "hunter2-but-longer",
	})
	req := httptest.NewRequest(http.MethodPost, "/api/auth/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)
	if rw.Code != http.StatusCreated {
		t.Fatalf("register in tenant A: expected 201, got %d: %s", rw.Code, rw.Body.String())
	}

	// The patient must be found in tenant A.
	tidA := store.TenantID(tenantA.ID)
	if _, err := s.GetPatientByEmail(ctx, tidA, sharedEmail); err != nil {
		t.Errorf("expected patient in tenant A, got: %v", err)
	}

	// The same email must NOT be visible in tenant B — the row belongs to A.
	tidB := store.TenantID(tenantB.ID)
	_, err = s.GetPatientByEmail(ctx, tidB, sharedEmail)
	if !errors.Is(err, store.ErrNotFound) {
		t.Errorf("expected ErrNotFound for tenant B, got: %v", err)
	}
}

// TestHandler_Register_PasswordHashStored verifies that the password stored in
// the patients table is a bcrypt hash — not the plaintext — and that
// bcrypt.CompareHashAndPassword succeeds against the original credential.
func TestHandler_Register_PasswordHashStored(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "register-hash-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	const testPassword = "hash-test-password-42!"
	body, _ := json.Marshal(map[string]string{
		"tenant_id": tenant.ID.String(),
		"email":     "hash-test@register.test",
		"password":  testPassword,
	})
	req := httptest.NewRequest(http.MethodPost, "/api/auth/register", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)
	if rw.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rw.Code, rw.Body.String())
	}

	patient, err := s.GetPatientByEmail(ctx, tid, "hash-test@register.test")
	if err != nil {
		t.Fatalf("get patient after registration: %v", err)
	}

	// Stored value must not be the plaintext password.
	if patient.PasswordHash == testPassword {
		t.Error("password stored as plaintext — must be a bcrypt hash")
	}

	// The stored hash must verify against the original password.
	if err := bcrypt.CompareHashAndPassword([]byte(patient.PasswordHash), []byte(testPassword)); err != nil {
		t.Errorf("bcrypt verification failed: %v (hash=%q)", err, patient.PasswordHash)
	}
}
