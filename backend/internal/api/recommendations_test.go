package api_test

// TestHandler_UnlicensedPhysicianReview_IsAudited is a handler-level integration
// test (using net/http/httptest) that exercises the real handleReviewRecommendation
// handler — not a mock — to verify the end-to-end path for an unlicensed
// physician's review attempt.
//
// Assertions:
//   - HTTP 403 is returned.
//   - The recommendation remains in PENDING_REVIEW (no state mutation).
//   - A recommendation.review_rejected audit row exists with reason=unlicensed_state.
//
// This test requires TEST_DATABASE_URL and skips when it is unset, matching the
// pattern used in internal/store tests.

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/markolonius/housecall/backend/internal/api"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/migrate"
	"github.com/markolonius/housecall/backend/internal/store"
)

// apiTestSecret is the HMAC-SHA256 key used for JWTs in handler tests.
var apiTestSecret = []byte("handler-test-secret-32-bytes!!!!")

// apiTestPool sets up a pgxpool connected to TEST_DATABASE_URL with migrations
// applied and all PHI tables truncated. Tests skip when the env var is unset.
func apiTestPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL not set; skipping DB-bound handler test")
	}

	ctx := context.Background()

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatalf("connect to test DB: %v", err)
	}
	defer conn.Close(ctx)

	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	migrationsDir := filepath.Join(filepath.Dir(file), "..", "..", "migrations")

	if _, err := migrate.Apply(ctx, conn, os.DirFS(migrationsDir)); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	_, err = conn.Exec(ctx, `
		TRUNCATE
			audit_events,
			recommendations,
			messages,
			conversations,
			care_relationships,
			physicians,
			patients,
			tenants
		RESTART IDENTITY CASCADE`)
	if err != nil {
		t.Fatalf("truncate: %v", err)
	}

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("create pool: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

// signedJWT builds an HS256 JWT that the api package's verifyToken will accept.
// The rawClaims layout matches the unexported rawClaims struct in api/jwt.go
// exactly: fields tid, sub, act, exp.
func signedJWT(secret []byte, tidStr, actorIDStr, actorType string) string {
	type rawClaims struct {
		TenantID  string `json:"tid"`
		ActorID   string `json:"sub"`
		ActorType string `json:"act"`
		Exp       int64  `json:"exp"`
	}
	rc := rawClaims{
		TenantID:  tidStr,
		ActorID:   actorIDStr,
		ActorType: actorType,
		Exp:       time.Now().Add(24 * time.Hour).Unix(),
	}
	hdr := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	payload, _ := json.Marshal(rc)
	enc := hdr + "." + base64.RawURLEncoding.EncodeToString(payload)
	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(enc))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return enc + "." + sig
}

// TestHandler_UnlicensedPhysicianReview_IsAudited drives an unlicensed
// physician's POST to /api/recommendations/{id}/review against the real router
// and handler and verifies three invariants:
//
//  1. The response is HTTP 403.
//  2. The recommendation state is still PENDING_REVIEW after the request.
//  3. A recommendation.review_rejected audit event row exists in the DB.
func TestHandler_UnlicensedPhysicianReview_IsAudited(t *testing.T) {
	pool := apiTestPool(t)
	s := store.New(pool)
	ctx := context.Background()

	// --- fixture ---

	tenant, err := s.CreateTenant(ctx, "dtc", "api-handler-test-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	// Patient is in CA; physician is licensed only in NY (not CA).
	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient@apihandler.test",
		FullName:     "Pat",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	physician, err := s.CreatePhysician(ctx, tid, store.Physician{
		Email:          "unlicensed@apihandler.test",
		FullName:       "Unlicensed Doc",
		StatesLicensed: []string{"NY"}, // not licensed in CA
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("create physician: %v", err)
	}

	// Care relationship needed so GetRecommendationForPhysician passes the
	// access-control JOIN and reaches the domain licensing check.
	if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, physician.ID); err != nil {
		t.Fatalf("care relationship: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "handler test conv")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	rec, err := s.CreateRecommendation(ctx, tid, store.Recommendation{
		ConversationID: conv.ID,
		PatientID:      patient.ID,
		State:          domain.StatePendingReview,
		PayloadType:    "guidance",
		Payload:        []byte(`{"text":"draft"}`),
		DraftContent:   "draft content",
	})
	if err != nil {
		t.Fatalf("create recommendation: %v", err)
	}

	// --- build the real router ---

	router := api.New(s, apiTestSecret)
	r := chi.NewRouter()
	router.Mount(r)

	// --- issue a JWT for the unlicensed physician ---

	token := signedJWT(apiTestSecret, tid.String(), physician.ID.String(), "physician")

	// --- send the review request ---

	body, _ := json.Marshal(map[string]string{"action": domain.ActionApprove})
	url := fmt.Sprintf("/api/recommendations/%s/review", rec.ID.String())
	req := httptest.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)

	rw := httptest.NewRecorder()
	r.ServeHTTP(rw, req)

	// --- assertion 1: HTTP 403 ---
	if rw.Code != http.StatusForbidden {
		t.Fatalf("expected HTTP 403, got %d (body: %s)", rw.Code, rw.Body.String())
	}

	// --- assertion 2: recommendation state unchanged ---
	got, err := s.GetRecommendation(ctx, tid, rec.ID)
	if err != nil {
		t.Fatalf("get recommendation after denied review: %v", err)
	}
	if got.State != domain.StatePendingReview {
		t.Fatalf("recommendation state was mutated: got %q, want %q",
			got.State, domain.StatePendingReview)
	}

	// --- assertion 3: audit event written ---
	var metadata []byte
	err = pool.QueryRow(ctx,
		`SELECT metadata FROM audit_events
		  WHERE tenant_id = $1
		    AND event_type  = 'recommendation.review_rejected'
		    AND actor_id    = $2`,
		tid.UUID(), physician.ID,
	).Scan(&metadata)
	if err != nil {
		t.Fatalf("expected recommendation.review_rejected audit event, got error: %v", err)
	}

	var meta map[string]any
	if err := json.Unmarshal(metadata, &meta); err != nil {
		t.Fatalf("unmarshal audit metadata: %v", err)
	}
	// Metadata must carry the reason and recommendation_id (identifiers only, no PHI).
	if meta["reason"] != "unlicensed_state" {
		t.Fatalf("audit metadata reason = %q, want %q", meta["reason"], "unlicensed_state")
	}
	if meta["recommendation_id"] != rec.ID.String() {
		t.Fatalf("audit metadata recommendation_id = %q, want %q",
			meta["recommendation_id"], rec.ID.String())
	}

	// Paranoia: confirm no PHI keys leaked into audit metadata.
	for _, phiKey := range []string{"patient_name", "full_name", "content", "draft_content", "final_content"} {
		if _, found := meta[phiKey]; found {
			t.Errorf("PHI key %q must not appear in audit metadata", phiKey)
		}
	}
}
