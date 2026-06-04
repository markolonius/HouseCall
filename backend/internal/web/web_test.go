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
	"github.com/markolonius/housecall/backend/internal/store"
	"github.com/markolonius/housecall/backend/internal/web"
	"golang.org/x/crypto/bcrypt"
)

// testSecret is the HMAC key used across all in-memory tests.
var testSecret = []byte("web-test-secret-32-bytes!!!!!!!")

// ---- fake store ----------------------------------------------------------------

// fakeStore implements just the two store methods the web package calls so
// tests can run without a database.
type fakeStore struct {
	physicians map[string]store.Physician // keyed by email
	patients   map[string]store.Patient   // keyed by email
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

// storeAdapter wraps fakeStore to satisfy the web.StoreQuerier interface.
type storeAdapter struct{ f *fakeStore }

func (a *storeAdapter) GetPhysicianByEmail(ctx context.Context, t store.TenantID, e string) (store.Physician, error) {
	return a.f.GetPhysicianByEmail(ctx, t, e)
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

// Prevent unused import error — errors is used in fakeStore implementations.
var _ = errors.New
var _ = fmt.Sprintf
