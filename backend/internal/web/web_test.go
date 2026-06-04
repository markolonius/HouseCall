package web_test

// web_test.go — httptest-based tests for the physician web app (task 5.1).
//
// Tests that do NOT need a real database use a fake store (fakeStore below)
// so they run without TEST_DATABASE_URL.  The DB-bound tests follow the same
// skip-when-unset pattern used by the rest of the backend test suite.
//
// Covered:
//   - TestLoginForm_GET               — GET /web/login returns 200 with a form
//   - TestLoginSubmit_MissingFields    — POST /web/login with blank fields → 400
//   - TestLoginSubmit_BadTenantID      — POST /web/login with garbled tenant_id → 400
//   - TestLoginSubmit_InvalidCreds     — POST /web/login bad password → 401, opaque
//   - TestLoginSubmit_PatientCreds     — POST /web/login with patient actor → 401
//   - TestLoginSubmit_Success          — POST /web/login ok → 303, HttpOnly cookie set
//   - TestRequireWebAuth_NoCookie      — authenticated route without cookie → redirect login
//   - TestRequireWebAuth_BadCookie     — authenticated route with tampered JWT → redirect login
//   - TestRequireWebAuth_NonPhysician  — authenticated route with patient JWT → redirect login
//   - TestRequireWebAuth_ValidPhysician — authenticated route with valid physician JWT → 200
//   - TestMiddlewareExtractsTenantAndIdentity — claims extracted into context correctly

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
	"github.com/markolonius/housecall/backend/internal/web"
	"golang.org/x/crypto/bcrypt"
)

// testSecret is the HMAC key used across all in-memory tests.
var testSecret = []byte("web-test-secret-32-bytes!!!!!!!")

// ---- fake store ----------------------------------------------------------------

// fakeStore implements the store methods the web package calls so tests can
// run without a database.
type fakeStore struct {
	physicians    map[string]store.Physician    // keyed by email
	patients      map[string]store.Patient      // keyed by email
	panelPatients []store.Patient               // returned by ListPatientsByPhysician
	queueRecs     []store.Recommendation        // returned by ListRecommendationsByPhysician
	// physicianForPanel / Rec scoping: keyed by physician id string
	panelByPhys map[string][]store.Patient
	recsByPhys  map[string][]store.Recommendation

	// review action support (task 5.3)
	recsByID      map[uuid.UUID]store.Recommendation // all recs by ID (for GetRecommendationForPhysician)
	physByID      map[uuid.UUID]store.Physician      // physicians by ID (for GetPhysician)
	patientsByID  map[uuid.UUID]store.Patient        // patients by ID (for GetPatient)
	auditEvents   []store.AuditEvent                 // captured audit events
	updatedStates map[uuid.UUID]string               // final state per recommendation (set by Txn)
	txnErr        error                              // if set, Txn returns this error
}

func (f *fakeStore) GetPhysicianByEmail(_ context.Context, tenant store.TenantID, email string) (store.Physician, error) {
	p, ok := f.physicians[email]
	if !ok || p.TenantID != tenant {
		return store.Physician{}, store.ErrNotFound
	}
	return p, nil
}

func (f *fakeStore) GetPatientByEmail(_ context.Context, tenant store.TenantID, email string) (store.Patient, error) {
	p, ok := f.patients[email]
	if !ok || p.TenantID != tenant {
		return store.Patient{}, store.ErrNotFound
	}
	return p, nil
}

// ListPatientsByPhysician returns patients scoped to tenant + physicianID.
// Uses panelByPhys if populated, otherwise falls back to panelPatients for
// simple tests that only have one physician.
func (f *fakeStore) ListPatientsByPhysician(_ context.Context, tenant store.TenantID, physicianID uuid.UUID) ([]store.Patient, error) {
	if f.panelByPhys != nil {
		key := physicianID.String()
		rows := f.panelByPhys[key]
		// Enforce tenant isolation: return only patients with matching tenant.
		var out []store.Patient
		for _, p := range rows {
			if p.TenantID == tenant {
				out = append(out, p)
			}
		}
		return out, nil
	}
	// Simple fallback: filter panelPatients by tenant.
	var out []store.Patient
	for _, p := range f.panelPatients {
		if p.TenantID == tenant {
			out = append(out, p)
		}
	}
	return out, nil
}

// ListRecommendationsByPhysician returns PENDING_REVIEW recs scoped to
// tenant + physicianID. Uses recsByPhys if populated.
func (f *fakeStore) ListRecommendationsByPhysician(_ context.Context, tenant store.TenantID, physicianID uuid.UUID, state string) ([]store.Recommendation, error) {
	if f.recsByPhys != nil {
		key := physicianID.String()
		rows := f.recsByPhys[key]
		var out []store.Recommendation
		for _, r := range rows {
			if r.TenantID == tenant && r.State == state {
				out = append(out, r)
			}
		}
		return out, nil
	}
	// Simple fallback: filter queueRecs by tenant and state.
	var out []store.Recommendation
	for _, r := range f.queueRecs {
		if r.TenantID == tenant && r.State == state {
			out = append(out, r)
		}
	}
	return out, nil
}

// ---- review action methods (task 5.3) ----

func (f *fakeStore) GetRecommendationForPhysician(_ context.Context, tenant store.TenantID, physicianID, recID uuid.UUID) (store.Recommendation, error) {
	r, ok := f.recsByID[recID]
	if !ok || r.TenantID != tenant {
		return store.Recommendation{}, store.ErrNotFound
	}
	// Check that the physician has an active care relationship (simulated by
	// verifying the physician is listed in recsByPhys for the patient).
	if f.recsByPhys != nil {
		found := false
		for _, rec := range f.recsByPhys[physicianID.String()] {
			if rec.ID == recID {
				found = true
				break
			}
		}
		if !found {
			return store.Recommendation{}, store.ErrNotFound
		}
	}
	return r, nil
}

func (f *fakeStore) GetPhysician(_ context.Context, tenant store.TenantID, id uuid.UUID) (store.Physician, error) {
	p, ok := f.physByID[id]
	if !ok || p.TenantID != tenant {
		return store.Physician{}, store.ErrNotFound
	}
	return p, nil
}

func (f *fakeStore) GetPatient(_ context.Context, tenant store.TenantID, id uuid.UUID) (store.Patient, error) {
	p, ok := f.patientsByID[id]
	if !ok || p.TenantID != tenant {
		return store.Patient{}, store.ErrNotFound
	}
	return p, nil
}

func (f *fakeStore) CreateAuditEvent(_ context.Context, _ store.TenantID, e store.AuditEvent) (store.AuditEvent, error) {
	f.auditEvents = append(f.auditEvents, e)
	return e, nil
}

// TxnW simulates a transaction by calling fn with a fakeTxWriter that
// captures UpdateRecommendationState calls into f.updatedStates and
// CreateAuditEvent calls into f.auditEvents.
func (f *fakeStore) TxnW(_ context.Context, fn func(store.TxWriter) error) error {
	if f.txnErr != nil {
		return f.txnErr
	}
	if f.updatedStates == nil {
		f.updatedStates = make(map[uuid.UUID]string)
	}
	return fn(&fakeTxWriter{f: f})
}

// fakeTxWriter implements store.TxWriter for DB-free tests.
type fakeTxWriter struct{ f *fakeStore }

func (t *fakeTxWriter) UpdateRecommendationState(_ context.Context, _ store.TenantID, id uuid.UUID, state string, _ *uuid.UUID, content *string) error {
	if t.f.updatedStates == nil {
		t.f.updatedStates = make(map[uuid.UUID]string)
	}
	t.f.updatedStates[id] = state
	// Update the recommendation in recsByID so subsequent reads reflect the new state.
	if rec, ok := t.f.recsByID[id]; ok {
		rec.State = state
		rec.FinalContent = content
		t.f.recsByID[id] = rec
	}
	return nil
}

func (t *fakeTxWriter) CreateAuditEvent(_ context.Context, _ store.TenantID, e store.AuditEvent) error {
	t.f.auditEvents = append(t.f.auditEvents, e)
	return nil
}

// storeAdapter wraps fakeStore to satisfy the web.StoreQuerier interface.
type storeAdapter struct{ f *fakeStore }

func (a *storeAdapter) GetPhysicianByEmail(ctx context.Context, t store.TenantID, e string) (store.Physician, error) {
	return a.f.GetPhysicianByEmail(ctx, t, e)
}

func (a *storeAdapter) ListPatientsByPhysician(ctx context.Context, t store.TenantID, physicianID uuid.UUID) ([]store.Patient, error) {
	return a.f.ListPatientsByPhysician(ctx, t, physicianID)
}

func (a *storeAdapter) ListRecommendationsByPhysician(ctx context.Context, t store.TenantID, physicianID uuid.UUID, state string) ([]store.Recommendation, error) {
	return a.f.ListRecommendationsByPhysician(ctx, t, physicianID, state)
}

func (a *storeAdapter) GetRecommendationForPhysician(ctx context.Context, t store.TenantID, physicianID, recID uuid.UUID) (store.Recommendation, error) {
	return a.f.GetRecommendationForPhysician(ctx, t, physicianID, recID)
}

func (a *storeAdapter) GetPhysician(ctx context.Context, t store.TenantID, id uuid.UUID) (store.Physician, error) {
	return a.f.GetPhysician(ctx, t, id)
}

func (a *storeAdapter) GetPatient(ctx context.Context, t store.TenantID, id uuid.UUID) (store.Patient, error) {
	return a.f.GetPatient(ctx, t, id)
}

func (a *storeAdapter) CreateAuditEvent(ctx context.Context, t store.TenantID, e store.AuditEvent) (store.AuditEvent, error) {
	return a.f.CreateAuditEvent(ctx, t, e)
}

func (a *storeAdapter) TxnW(ctx context.Context, fn func(store.TxWriter) error) error {
	return a.f.TxnW(ctx, fn)
}

// noopAuditWriter discards all audit events for tests that don't need a DB.
type noopAuditWriter struct{}

func (n *noopAuditWriter) Write(_ context.Context, _ store.TenantID, _ string, _ *uuid.UUID, _ string, _ map[string]any) {
}

// ---- test helpers ---------------------------------------------------------------

func mustHashPassword(t *testing.T, password string) string {
	t.Helper()
	h, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.MinCost)
	if err != nil {
		t.Fatalf("hash password: %v", err)
	}
	return string(h)
}

// buildHandler creates a web.Handler backed by the given fakeStore and mounts
// it on a fresh chi router, returning the router ready for httptest.
func buildHandler(t *testing.T, fs *fakeStore) http.Handler {
	t.Helper()
	h, err := web.NewWithQuerier(&storeAdapter{fs}, testSecret, &noopAuditWriter{})
	if err != nil {
		t.Fatalf("web.NewWithQuerier: %v", err)
	}
	r := chi.NewRouter()
	h.Mount(r)
	return r
}

// makeCookie issues a signed session cookie for the given claims without
// going through the login form, so auth-middleware tests can inject cookies
// directly.
func makeCookie(t *testing.T, tenantID store.TenantID, actorID uuid.UUID, actorType string) *http.Cookie {
	t.Helper()
	token, err := web.IssueTestToken(testSecret, tenantID, actorID, actorType)
	if err != nil {
		t.Fatalf("issue test token: %v", err)
	}
	return &http.Cookie{Name: "hc_session", Value: token}
}

func makeExpiredCookie(t *testing.T, tenantID store.TenantID, actorID uuid.UUID, actorType string) *http.Cookie {
	t.Helper()
	token, err := web.IssueTestTokenWithTTL(testSecret, tenantID, actorID, actorType, -time.Minute)
	if err != nil {
		t.Fatalf("issue expired test token: %v", err)
	}
	return &http.Cookie{Name: "hc_session", Value: token}
}

// ---- tests -----------------------------------------------------------------------

var (
	testTenantID  = store.TenantID(uuid.MustParse("aaaaaaaa-0000-0000-0000-000000000001"))
	testPhysID    = uuid.MustParse("bbbbbbbb-0000-0000-0000-000000000002")
	testPatientID = uuid.MustParse("cccccccc-0000-0000-0000-000000000003")
)

func newFakeStoreWithPhysician(t *testing.T, password string) *fakeStore {
	return &fakeStore{
		physicians: map[string]store.Physician{
			"doc@clinic.example": {
				ID:           testPhysID,
				TenantID:     testTenantID,
				Email:        "doc@clinic.example",
				PasswordHash: mustHashPassword(t, password),
			},
		},
	}
}

// TestLoginForm_GET verifies that GET /web/login returns 200 and renders an HTML form.
func TestLoginForm_GET(t *testing.T) {
	h := buildHandler(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/login", nil)
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "<form") {
		t.Error("expected a <form> element in the login page")
	}
	if !strings.Contains(body, "tenant_id") {
		t.Error("expected tenant_id field in the login page")
	}
}

// TestLoginSubmit_MissingFields verifies that a POST with blank fields returns 400.
func TestLoginSubmit_MissingFields(t *testing.T) {
	h := buildHandler(t, &fakeStore{})
	form := url.Values{"tenant_id": {""}, "email": {""}, "password": {""}}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/web/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", rec.Code)
	}
}

// TestLoginSubmit_BadTenantID verifies that a non-UUID tenant_id returns 400.
func TestLoginSubmit_BadTenantID(t *testing.T) {
	h := buildHandler(t, &fakeStore{})
	form := url.Values{"tenant_id": {"not-a-uuid"}, "email": {"doc@clinic.example"}, "password": {"secret"}}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/web/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Fatalf("want 400, got %d", rec.Code)
	}
}

// TestLoginSubmit_InvalidCreds verifies that wrong password returns 401 with an
// opaque message (no enumeration hint).
func TestLoginSubmit_InvalidCreds(t *testing.T) {
	h := buildHandler(t, newFakeStoreWithPhysician(t, "correct-password"))
	form := url.Values{
		"tenant_id": {testTenantID.String()},
		"email":     {"doc@clinic.example"},
		"password":  {"wrong-password"},
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/web/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
	body := rec.Body.String()
	if strings.Contains(body, "doc@clinic.example") {
		t.Error("response must not echo back the email (enumeration risk)")
	}
}

// TestLoginSubmit_UnknownEmail verifies that an unknown email returns 401 with the
// same opaque message (prevents account enumeration).
func TestLoginSubmit_UnknownEmail(t *testing.T) {
	h := buildHandler(t, newFakeStoreWithPhysician(t, "correct-password"))
	form := url.Values{
		"tenant_id": {testTenantID.String()},
		"email":     {"unknown@clinic.example"},
		"password":  {"correct-password"},
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/web/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("want 401, got %d", rec.Code)
	}
}

// TestLoginSubmit_Success verifies that correct physician credentials:
//   - Return a 303 redirect to /web/queue
//   - Set a session cookie that is HttpOnly
func TestLoginSubmit_Success(t *testing.T) {
	const password = "Str0ng!Password#99"
	h := buildHandler(t, newFakeStoreWithPhysician(t, password))
	form := url.Values{
		"tenant_id": {testTenantID.String()},
		"email":     {"doc@clinic.example"},
		"password":  {password},
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodPost, "/web/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("want 303, got %d", rec.Code)
	}
	if loc := rec.Header().Get("Location"); loc != "/web/queue" {
		t.Fatalf("want redirect to /web/queue, got %q", loc)
	}

	// Find the session cookie.
	var sessionCookie *http.Cookie
	for _, c := range rec.Result().Cookies() {
		if c.Name == "hc_session" {
			sessionCookie = c
			break
		}
	}
	if sessionCookie == nil {
		t.Fatal("expected hc_session cookie to be set")
	}
	if !sessionCookie.HttpOnly {
		t.Error("session cookie must be HttpOnly")
	}
	if !sessionCookie.Secure {
		t.Error("session cookie must be Secure")
	}
	if sessionCookie.SameSite != http.SameSiteLaxMode && sessionCookie.SameSite != http.SameSiteStrictMode {
		t.Errorf("session cookie SameSite must be Lax or Strict, got %v", sessionCookie.SameSite)
	}
	if sessionCookie.Value == "" {
		t.Error("session cookie must carry a token value")
	}
}

// TestRequireWebAuth_NoCookie verifies that an unauthenticated request to a
// protected route redirects to the login form.
func TestRequireWebAuth_NoCookie(t *testing.T) {
	h := buildHandlerWithProtectedRoute(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/protected", nil)
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestRequireWebAuth_BadCookie verifies that a tampered JWT redirects to login.
func TestRequireWebAuth_BadCookie(t *testing.T) {
	h := buildHandlerWithProtectedRoute(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/protected", nil)
	req.AddCookie(&http.Cookie{Name: "hc_session", Value: "tampered.header.value"})
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestRequireWebAuth_ExpiredCookie verifies that an expired JWT redirects to login
// and clears the stale cookie.
func TestRequireWebAuth_ExpiredCookie(t *testing.T) {
	h := buildHandlerWithProtectedRoute(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/protected", nil)
	req.AddCookie(makeExpiredCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)

	// Expired cookie should be cleared (MaxAge < 0 or empty value).
	cleared := false
	for _, c := range rec.Result().Cookies() {
		if c.Name == "hc_session" && (c.MaxAge < 0 || c.Value == "") {
			cleared = true
		}
	}
	if !cleared {
		t.Error("expected stale hc_session cookie to be cleared on expiry redirect")
	}
}

// TestRequireWebAuth_NonPhysician verifies that a valid JWT for a patient
// (non-physician actor) is rejected with a redirect to login.
func TestRequireWebAuth_NonPhysician(t *testing.T) {
	h := buildHandlerWithProtectedRoute(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/protected", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPatientID, "patient"))
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestRequireWebAuth_ValidPhysician verifies that a valid physician JWT reaches
// the protected handler (returns 200).
func TestRequireWebAuth_ValidPhysician(t *testing.T) {
	h := buildHandlerWithProtectedRoute(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/protected", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
}

// TestMiddlewareExtractsTenantAndIdentity verifies that requireWebAuth injects
// the correct tenant_id and actor_id into the request context.
func TestMiddlewareExtractsTenantAndIdentity(t *testing.T) {
	var gotClaims web.WebClaims
	var claimsOK bool

	// Build the middleware-only handler directly (no Mount, no chi router needed).
	inner := http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		gotClaims, claimsOK = web.WebClaimsFromCtx(req.Context())
		w.WriteHeader(http.StatusOK)
	})
	h := buildProtectedHandler(t, &fakeStore{}, inner)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/probe", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	if !claimsOK {
		t.Fatal("claims were not injected into context")
	}
	if gotClaims.TenantID != testTenantID {
		t.Errorf("want tenant %s, got %s", testTenantID, gotClaims.TenantID)
	}
	if gotClaims.ActorID != testPhysID {
		t.Errorf("want actorID %s, got %s", testPhysID, gotClaims.ActorID)
	}
	if gotClaims.ActorType != "physician" {
		t.Errorf("want actorType physician, got %s", gotClaims.ActorType)
	}
}

// ---- helpers for protected route tests ------------------------------------------

// buildProtectedHandler wraps inner with the requireWebAuth middleware from a
// freshly constructed Handler, without mounting any chi router.
func buildProtectedHandler(t *testing.T, fs *fakeStore, inner http.Handler) http.Handler {
	t.Helper()
	h, err := web.NewWithQuerier(&storeAdapter{fs}, testSecret, &noopAuditWriter{})
	if err != nil {
		t.Fatalf("web.NewWithQuerier: %v", err)
	}
	return web.ExportedRequireWebAuth(h)(inner)
}

// buildHandlerWithProtectedRoute wraps a 200-OK handler with requireWebAuth.
// It does NOT call h.Mount so there is no chi router path conflict.
func buildHandlerWithProtectedRoute(t *testing.T, fs *fakeStore) http.Handler {
	t.Helper()
	return buildProtectedHandler(t, fs, http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
}

func assertRedirectToLogin(t *testing.T, rec *httptest.ResponseRecorder) {
	t.Helper()
	if rec.Code != http.StatusSeeOther && rec.Code != http.StatusFound {
		t.Fatalf("expected redirect (302/303), got %d", rec.Code)
	}
	loc := rec.Header().Get("Location")
	if !strings.Contains(loc, "/web/login") {
		t.Errorf("expected redirect to /web/login, got %q", loc)
	}
}

// ---- panel tests ----------------------------------------------------------------

// testPhysID2 / testTenantID2 represent a second physician in a second tenant
// used to verify isolation.
var (
	testTenantID2 = store.TenantID(uuid.MustParse("dddddddd-0000-0000-0000-000000000004"))
	testPhysID2   = uuid.MustParse("eeeeeeee-0000-0000-0000-000000000005")
	testPatientID2 = uuid.MustParse("ffffffff-0000-0000-0000-000000000006")
)

// TestPanel_Unauthenticated verifies that GET /web/panel without a session
// cookie redirects to the login form.
func TestPanel_Unauthenticated(t *testing.T) {
	h := buildHandler(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/panel", nil)
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestPanel_NonPhysician verifies that a patient JWT is rejected for /web/panel.
func TestPanel_NonPhysician(t *testing.T) {
	h := buildHandler(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/panel", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPatientID, "patient"))
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestPanel_ShowsOnlySessionPhysicianPatients verifies that GET /web/panel
// renders only the care-relationship patients for the session physician, and
// does NOT render patients belonging to a second physician in another tenant.
func TestPanel_ShowsOnlySessionPhysicianPatients(t *testing.T) {
	phys1Patient := store.Patient{
		ID:       testPatientID,
		TenantID: testTenantID,
		FullName: "Alice Smith",
		State:    "CA",
	}
	phys2Patient := store.Patient{
		ID:       testPatientID2,
		TenantID: testTenantID2,
		FullName: "Bob Jones",
		State:    "NY",
	}

	fs := &fakeStore{
		physicians: map[string]store.Physician{},
		panelByPhys: map[string][]store.Patient{
			testPhysID.String():  {phys1Patient},
			testPhysID2.String(): {phys2Patient},
		},
	}

	h := buildHandler(t, fs)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/panel", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Alice Smith") {
		t.Error("panel must show phys1's patient (Alice Smith)")
	}
	// Bob Jones belongs to testPhysID2 under testTenantID2; must not appear.
	if strings.Contains(body, "Bob Jones") {
		t.Error("panel must NOT show another physician's patient (Bob Jones)")
	}
}

// TestPanel_EmptyPanel verifies that an empty panel renders without error.
func TestPanel_EmptyPanel(t *testing.T) {
	fs := &fakeStore{
		physicians:  map[string]store.Physician{},
		panelPatients: nil,
	}
	h := buildHandler(t, fs)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/panel", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "No active patients") {
		t.Error("empty panel must show the empty-state message")
	}
}

// ---- queue tests ----------------------------------------------------------------

// TestQueue_Unauthenticated verifies that GET /web/queue without a session
// cookie redirects to the login form.
func TestQueue_Unauthenticated(t *testing.T) {
	h := buildHandler(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/queue", nil)
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestQueue_NonPhysician verifies that a patient JWT is rejected for /web/queue.
func TestQueue_NonPhysician(t *testing.T) {
	h := buildHandler(t, &fakeStore{physicians: map[string]store.Physician{}})
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/queue", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPatientID, "patient"))
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestQueue_ShowsOnlySessionPhysicianRecs verifies that GET /web/queue renders
// PENDING_REVIEW recommendations for the session physician only, and does NOT
// render recommendations belonging to a second physician in another tenant.
func TestQueue_ShowsOnlySessionPhysicianRecs(t *testing.T) {
	phys1Rec := store.Recommendation{
		ID:          uuid.MustParse("11111111-0000-0000-0000-000000000001"),
		TenantID:    testTenantID,
		PatientID:   testPatientID,
		State:       "PENDING_REVIEW",
		PayloadType: "guidance",
		DraftContent: "Rest and hydrate",
	}
	phys2Rec := store.Recommendation{
		ID:          uuid.MustParse("22222222-0000-0000-0000-000000000002"),
		TenantID:    testTenantID2,
		PatientID:   testPatientID2,
		State:       "PENDING_REVIEW",
		PayloadType: "prescription",
		DraftContent: "Take ibuprofen",
	}

	fs := &fakeStore{
		physicians: map[string]store.Physician{},
		recsByPhys: map[string][]store.Recommendation{
			testPhysID.String():  {phys1Rec},
			testPhysID2.String(): {phys2Rec},
		},
	}

	h := buildHandler(t, fs)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/queue", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Rest and hydrate") {
		t.Error("queue must show phys1's recommendation draft")
	}
	// Take ibuprofen belongs to testPhysID2 / testTenantID2; must not appear.
	if strings.Contains(body, "Take ibuprofen") {
		t.Error("queue must NOT show another physician's recommendation")
	}
}

// TestQueue_OnlyPendingReview verifies that the queue does not surface
// recommendations in other states (DRAFT, APPROVED, etc.) even if the fake
// returns them mixed — i.e. the fake enforces the state filter and the
// handler passes the correct state argument.
func TestQueue_OnlyPendingReview(t *testing.T) {
	pending := store.Recommendation{
		ID:          uuid.MustParse("33333333-0000-0000-0000-000000000003"),
		TenantID:    testTenantID,
		PatientID:   testPatientID,
		State:       "PENDING_REVIEW",
		PayloadType: "guidance",
		DraftContent: "Drink water",
	}
	draft := store.Recommendation{
		ID:          uuid.MustParse("44444444-0000-0000-0000-000000000004"),
		TenantID:    testTenantID,
		PatientID:   testPatientID,
		State:       "DRAFT",
		PayloadType: "guidance",
		DraftContent: "This is a draft",
	}

	// Use simple queueRecs fallback — the fake filters by state.
	fs := &fakeStore{
		physicians: map[string]store.Physician{},
		queueRecs:  []store.Recommendation{pending, draft},
	}

	h := buildHandler(t, fs)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/queue", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "Drink water") {
		t.Error("queue must show PENDING_REVIEW recommendation")
	}
	if strings.Contains(body, "This is a draft") {
		t.Error("queue must NOT show DRAFT recommendation")
	}
}

// TestQueue_EmptyQueue verifies that an empty queue renders without error.
func TestQueue_EmptyQueue(t *testing.T) {
	fs := &fakeStore{
		physicians: map[string]store.Physician{},
		queueRecs:  nil,
	}
	h := buildHandler(t, fs)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/queue", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("want 200, got %d", rec.Code)
	}
	body := rec.Body.String()
	if !strings.Contains(body, "No pending recommendations") {
		t.Error("empty queue must show the empty-state message")
	}
}

// TestNavLinks_PanelAndQueue verifies that the layout nav includes links to
// both /web/panel and /web/queue when viewing authenticated pages.
func TestNavLinks_PanelAndQueue(t *testing.T) {
	fs := &fakeStore{
		physicians: map[string]store.Physician{},
		panelPatients: nil,
	}
	h := buildHandler(t, fs)

	for _, path := range []string{"/web/panel", "/web/queue"} {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(http.MethodGet, path, nil)
		req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
		h.ServeHTTP(rec, req)

		if rec.Code != http.StatusOK {
			t.Fatalf("%s: want 200, got %d", path, rec.Code)
		}
		body := rec.Body.String()
		if !strings.Contains(body, `href="/web/panel"`) {
			t.Errorf("%s: page must contain nav link to /web/panel", path)
		}
		if !strings.Contains(body, `href="/web/queue"`) {
			t.Errorf("%s: page must contain nav link to /web/queue", path)
		}
	}
}

// ---- review action tests (task 5.3) ---------------------------------------------

// testRecID is a stable recommendation UUID used across review action tests.
var testRecID = uuid.MustParse("55555555-0000-0000-0000-000000000005")

// newFakeStoreForReview returns a fakeStore pre-populated with a PENDING_REVIEW
// recommendation, a physician (with given states_licensed), and their patient (in state patientState).
func newFakeStoreForReview(physStates []string, patientState string) *fakeStore {
	phys := store.Physician{
		ID:             testPhysID,
		TenantID:       testTenantID,
		Email:          "doc@clinic.example",
		StatesLicensed: physStates,
	}
	patient := store.Patient{
		ID:       testPatientID,
		TenantID: testTenantID,
		State:    patientState,
	}
	rec := store.Recommendation{
		ID:           testRecID,
		TenantID:     testTenantID,
		PatientID:    testPatientID,
		State:        domain.StatePendingReview,
		PayloadType:  "guidance",
		DraftContent: "Drink plenty of water and rest",
	}
	return &fakeStore{
		physicians:   map[string]store.Physician{"doc@clinic.example": phys},
		physByID:     map[uuid.UUID]store.Physician{testPhysID: phys},
		patientsByID: map[uuid.UUID]store.Patient{testPatientID: patient},
		recsByID:     map[uuid.UUID]store.Recommendation{testRecID: rec},
		// recsByPhys wires the care-relationship check in GetRecommendationForPhysician.
		recsByPhys: map[string][]store.Recommendation{
			testPhysID.String(): {rec},
		},
		updatedStates: make(map[uuid.UUID]string),
	}
}

// postReview sends a POST to /web/recommendations/{id}/review with the given
// action and optional final_content, using the session cookie for testPhysID.
func postReview(t *testing.T, h http.Handler, recID uuid.UUID, action, finalContent string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{"action": {action}}
	if finalContent != "" {
		form.Set("final_content", finalContent)
	}
	req := httptest.NewRequest(http.MethodPost,
		"/web/recommendations/"+recID.String()+"/review",
		strings.NewReader(form.Encode()),
	)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

// TestReview_Unauthenticated verifies that an unauthenticated POST to the
// review endpoint redirects to login.
func TestReview_Unauthenticated(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)

	form := url.Values{"action": {"approve"}}
	req := httptest.NewRequest(http.MethodPost,
		"/web/recommendations/"+testRecID.String()+"/review",
		strings.NewReader(form.Encode()),
	)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestReview_NonPhysician verifies that a patient JWT is rejected.
func TestReview_NonPhysician(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)

	form := url.Values{"action": {"approve"}}
	req := httptest.NewRequest(http.MethodPost,
		"/web/recommendations/"+testRecID.String()+"/review",
		strings.NewReader(form.Encode()),
	)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(makeCookie(t, testTenantID, testPatientID, "patient"))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	assertRedirectToLogin(t, rec)
}

// TestReview_Approve verifies that POSTing action=approve:
//   - Redirects back to /web/queue (303)
//   - Drives the recommendation to DELIVERED
//   - Sets final_content to the draft (no override provided)
//   - Writes a recommendation.reviewed audit event
func TestReview_Approve(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)

	rec := postReview(t, h, testRecID, domain.ActionApprove, "")

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("approve: want 303, got %d (body: %s)", rec.Code, rec.Body.String())
	}
	if loc := rec.Header().Get("Location"); loc != "/web/queue" {
		t.Fatalf("approve: want redirect to /web/queue, got %q", loc)
	}

	// The recommendation must have reached DELIVERED.
	if got := fs.updatedStates[testRecID]; got != domain.StateDelivered {
		t.Fatalf("approve: want state DELIVERED, got %q", got)
	}

	// A recommendation.reviewed audit event must have been written.
	assertAuditEvent(t, fs, "recommendation.reviewed", domain.ActionApprove, domain.StateDelivered)
}

// TestReview_Reject verifies that POSTing action=reject drives the
// recommendation to REJECTED and redirects to the queue.
func TestReview_Reject(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)

	rec := postReview(t, h, testRecID, domain.ActionReject, "")

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("reject: want 303, got %d (body: %s)", rec.Code, rec.Body.String())
	}

	if got := fs.updatedStates[testRecID]; got != domain.StateRejected {
		t.Fatalf("reject: want state REJECTED, got %q", got)
	}

	// Verify final_content is nil (patients must never see a rejected rec's content).
	if r, ok := fs.recsByID[testRecID]; ok && r.FinalContent != nil {
		t.Error("reject: final_content must remain nil for REJECTED recommendations")
	}

	assertAuditEvent(t, fs, "recommendation.reviewed", domain.ActionReject, domain.StateRejected)
}

// TestReview_Modify verifies that POSTing action=modify with final_content:
//   - Drives the recommendation to DELIVERED
//   - Sets final_content to the physician's edited value
//   - Redirects to the queue
func TestReview_Modify(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)
	editedContent := "Take ibuprofen 400 mg twice daily"

	rec := postReview(t, h, testRecID, domain.ActionModify, editedContent)

	if rec.Code != http.StatusSeeOther {
		t.Fatalf("modify: want 303, got %d (body: %s)", rec.Code, rec.Body.String())
	}

	if got := fs.updatedStates[testRecID]; got != domain.StateDelivered {
		t.Fatalf("modify: want state DELIVERED, got %q", got)
	}

	// final_content must equal the physician's edited text.
	r := fs.recsByID[testRecID]
	if r.FinalContent == nil {
		t.Fatal("modify: final_content must be set after delivery")
	}
	if *r.FinalContent != editedContent {
		t.Fatalf("modify: final_content = %q, want %q", *r.FinalContent, editedContent)
	}

	assertAuditEvent(t, fs, "recommendation.reviewed", domain.ActionModify, domain.StateDelivered)
}

// TestReview_ModifyMissingFinalContent verifies that a modify action without
// final_content is rejected (400) and state is not mutated.
func TestReview_ModifyMissingFinalContent(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)

	rec := postReview(t, h, testRecID, domain.ActionModify, "")

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("modify without content: want 400, got %d", rec.Code)
	}
	// State must not have changed.
	if _, changed := fs.updatedStates[testRecID]; changed {
		t.Error("modify without content: state must not be mutated")
	}
}

// TestReview_UnlicensedPhysician verifies that an unlicensed physician:
//   - Receives a 403 response with the queue re-rendered
//   - Does NOT mutate state
//   - Has a recommendation.review_rejected audit event written
func TestReview_UnlicensedPhysician(t *testing.T) {
	// Physician licensed in NY, patient in CA.
	fs := newFakeStoreForReview([]string{"NY"}, "CA")
	h := buildHandler(t, fs)

	rec := postReview(t, h, testRecID, domain.ActionApprove, "")

	if rec.Code != http.StatusForbidden {
		t.Fatalf("unlicensed: want 403, got %d (body: %s)", rec.Code, rec.Body.String())
	}

	// The recommendation state must NOT have been updated.
	if _, changed := fs.updatedStates[testRecID]; changed {
		t.Error("unlicensed: state must not be mutated when physician is unlicensed")
	}

	// A review_rejected audit event must have been written.
	found := false
	for _, e := range fs.auditEvents {
		if e.EventType == "recommendation.review_rejected" {
			var meta map[string]any
			if err := json.Unmarshal(e.Metadata, &meta); err == nil {
				if meta["reason"] == "unlicensed_state" {
					found = true
				}
			}
		}
	}
	if !found {
		t.Error("unlicensed: expected recommendation.review_rejected audit event with reason=unlicensed_state")
	}

	// Queue page must be re-rendered (not a redirect).
	body := rec.Body.String()
	if !strings.Contains(body, "not licensed in the patient") {
		t.Error("unlicensed: response body must contain physician-facing error message")
	}
}

// TestReview_NotOwnPatient verifies that a physician cannot act on a
// recommendation belonging to a patient outside their care relationship.
func TestReview_NotOwnPatient(t *testing.T) {
	// testPhysID2 is NOT in testPhysID's recsByPhys.
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	// Change the rec to belong to phys2's patient.
	unrelatedRec := store.Recommendation{
		ID:           uuid.MustParse("66666666-0000-0000-0000-000000000006"),
		TenantID:     testTenantID,
		PatientID:    testPatientID2,
		State:        domain.StatePendingReview,
		PayloadType:  "guidance",
		DraftContent: "Another recommendation",
	}
	fs.recsByID[unrelatedRec.ID] = unrelatedRec
	// testPhysID's recsByPhys does NOT include unrelatedRec, so GetRecommendationForPhysician returns 404.

	h := buildHandler(t, fs)

	form := url.Values{"action": {"approve"}}
	req := httptest.NewRequest(http.MethodPost,
		"/web/recommendations/"+unrelatedRec.ID.String()+"/review",
		strings.NewReader(form.Encode()),
	)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("not-own-patient: want 404, got %d", rec.Code)
	}
}

// TestReview_InvalidRecID verifies that a non-UUID recommendation id returns 400.
func TestReview_InvalidRecID(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)

	form := url.Values{"action": {"approve"}}
	req := httptest.NewRequest(http.MethodPost, "/web/recommendations/not-a-uuid/review",
		strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("invalid id: want 400, got %d", rec.Code)
	}
}

// TestReview_QueueShowsActionForms verifies that the queue page renders Approve,
// Reject, and Modify controls for a PENDING_REVIEW recommendation.
func TestReview_QueueShowsActionForms(t *testing.T) {
	rec := store.Recommendation{
		ID:           testRecID,
		TenantID:     testTenantID,
		PatientID:    testPatientID,
		State:        domain.StatePendingReview,
		PayloadType:  "guidance",
		DraftContent: "Take vitamin D",
	}
	fs := &fakeStore{
		physicians: map[string]store.Physician{},
		queueRecs:  []store.Recommendation{rec},
	}
	h := buildHandler(t, fs)

	rw := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/web/queue", nil)
	req.AddCookie(makeCookie(t, testTenantID, testPhysID, "physician"))
	h.ServeHTTP(rw, req)

	if rw.Code != http.StatusOK {
		t.Fatalf("queue with rec: want 200, got %d", rw.Code)
	}
	body := rw.Body.String()

	// Must contain review action forms.
	if !strings.Contains(body, `value="approve"`) {
		t.Error("queue must contain an approve action")
	}
	if !strings.Contains(body, `value="reject"`) {
		t.Error("queue must contain a reject action")
	}
	if !strings.Contains(body, `value="modify"`) {
		t.Error("queue must contain a modify action")
	}
	// final_content textarea for the modify flow.
	if !strings.Contains(body, `name="final_content"`) {
		t.Error("queue must contain a final_content input for the modify flow")
	}
}

// assertAuditEvent is a helper that verifies the fakeStore has an audit event
// of the given type with matching action and new_state metadata fields.
func assertAuditEvent(t *testing.T, fs *fakeStore, eventType, action, newState string) {
	t.Helper()
	for _, e := range fs.auditEvents {
		if e.EventType != eventType {
			continue
		}
		var meta map[string]any
		if err := json.Unmarshal(e.Metadata, &meta); err != nil {
			continue
		}
		if meta["action"] == action && meta["new_state"] == newState {
			return
		}
	}
	t.Errorf("expected audit event type=%q action=%q new_state=%q; got events: %v",
		eventType, action, newState, auditEventSummary(fs))
}

func auditEventSummary(fs *fakeStore) []string {
	var out []string
	for _, e := range fs.auditEvents {
		out = append(out, e.EventType+":"+string(e.Metadata))
	}
	return out
}

// TestReview_PhysicianNotFound verifies that when the session actor's physician
// record cannot be resolved (review.ErrActorNotFound), the web handler redirects
// to /web/login (treating it as an auth anomaly, not a normal 404).
func TestReview_PhysicianNotFound(t *testing.T) {
	// Build a store where the recommendation exists but the physician record does
	// not (physByID is empty → GetPhysician returns ErrNotFound → ErrActorNotFound).
	patient := store.Patient{
		ID:       testPatientID,
		TenantID: testTenantID,
		State:    "CA",
	}
	rec := store.Recommendation{
		ID:           testRecID,
		TenantID:     testTenantID,
		PatientID:    testPatientID,
		State:        domain.StatePendingReview,
		PayloadType:  "guidance",
		DraftContent: "Drink water",
	}
	fs := &fakeStore{
		physicians:   map[string]store.Physician{},
		physByID:     map[uuid.UUID]store.Physician{}, // empty → GetPhysician returns ErrNotFound
		patientsByID: map[uuid.UUID]store.Patient{testPatientID: patient},
		recsByID:     map[uuid.UUID]store.Recommendation{testRecID: rec},
		recsByPhys: map[string][]store.Recommendation{
			testPhysID.String(): {rec},
		},
		updatedStates: make(map[uuid.UUID]string),
	}

	h := buildHandler(t, fs)
	resp := postReview(t, h, testRecID, domain.ActionApprove, "")

	// Physician-not-found is an auth/session anomaly → redirect to login.
	if resp.Code != http.StatusSeeOther && resp.Code != http.StatusFound {
		t.Fatalf("physician not found: want redirect (302/303), got %d", resp.Code)
	}
	loc := resp.Header().Get("Location")
	if !strings.Contains(loc, "/web/login") {
		t.Fatalf("physician not found: expected redirect to /web/login, got %q", loc)
	}
	// State must not have been mutated.
	if _, changed := fs.updatedStates[testRecID]; changed {
		t.Error("physician not found: state must not be mutated")
	}
}

// TestReview_ExactlyOneAuditEvent verifies that a successful web review
// produces exactly ONE recommendation.reviewed audit event — the atomic event
// written by review.Execute — and not a second out-of-transaction event.
func TestReview_ExactlyOneAuditEvent(t *testing.T) {
	fs := newFakeStoreForReview([]string{"CA"}, "CA")
	h := buildHandler(t, fs)

	resp := postReview(t, h, testRecID, domain.ActionApprove, "")
	if resp.Code != http.StatusSeeOther {
		t.Fatalf("approve: want 303, got %d (body: %s)", resp.Code, resp.Body.String())
	}

	var count int
	for _, e := range fs.auditEvents {
		if e.EventType == "recommendation.reviewed" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("expected exactly 1 recommendation.reviewed audit event, got %d (events: %v)",
			count, auditEventSummary(fs))
	}
}

// Prevent unused import error — errors is used in fakeStore implementations.
var _ = errors.New
var _ = fmt.Sprintf
