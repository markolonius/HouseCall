package web_test

// care_phase_delivery_test.go — DB-backed integration tests for task 2.4:
// when a recommendation reaches DELIVERED through the physician web review
// handler, the conversation's care_phase must move AWAITING_REVIEW ->
// PLAN_DELIVERED in the same delivery transaction.
//
// These tests drive the real handleReview handler (web.New, not
// NewWithQuerier) against a real Postgres database so the assertion covers
// the actual store.TxStore.TransitionCarePhase call inside review.Execute's
// TxnW, not a fake. They require TEST_DATABASE_URL and skip when unset,
// matching the pattern used by internal/api/recommendations_test.go.

import (
	"context"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/go-chi/chi/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/markolonius/housecall/backend/internal/audit"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/migrate"
	"github.com/markolonius/housecall/backend/internal/store"
	"github.com/markolonius/housecall/backend/internal/web"
)

// carePhaseTestPool connects to TEST_DATABASE_URL, applies migrations, and
// truncates every PHI-bearing table so each test starts from a clean slate.
func carePhaseTestPool(t *testing.T) *pgxpool.Pool {
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

// carePhaseDeliveryFixture holds the seeded rows a review test needs.
type carePhaseDeliveryFixture struct {
	tenant    store.TenantID
	physician store.Physician
	patient   store.Patient
	conv      store.Conversation
	rec       store.Recommendation
}

// seedCarePhaseDeliveryFixture creates a tenant, a licensed physician, a
// patient, an active care relationship, a conversation seeded directly into
// AWAITING_REVIEW (mirroring where task 2.2's SOAP-draft commit leaves it),
// and a PENDING_REVIEW recommendation attached to that conversation.
func seedCarePhaseDeliveryFixture(t *testing.T, s *store.Store) carePhaseDeliveryFixture {
	t.Helper()
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "care-phase-delivery-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	phys, err := s.CreatePhysician(ctx, tid, store.Physician{
		Email:          "doc@" + uuid.NewString() + ".test",
		FullName:       "Review Physician",
		StatesLicensed: []string{"CA"},
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("create physician: %v", err)
	}

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient@" + uuid.NewString() + ".test",
		FullName:     "Review Patient",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, phys.ID); err != nil {
		t.Fatalf("create care relationship: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "care phase delivery test")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	// Fast-forward to AWAITING_REVIEW via the same CAS helper task 2.2 uses,
	// so the fixture starts in the state a real SOAP-draft commit leaves it.
	if err := s.Txn(ctx, func(tx *store.TxStore) error {
		return tx.TransitionCarePhase(ctx, tid, conv.ID, store.CarePhaseIntake, store.CarePhaseAwaitingReview)
	}); err != nil {
		t.Fatalf("seed AWAITING_REVIEW: %v", err)
	}
	conv.CarePhase = store.CarePhaseAwaitingReview

	rec, err := s.CreateRecommendation(ctx, tid, store.Recommendation{
		ConversationID: conv.ID,
		PatientID:      patient.ID,
		State:          domain.StatePendingReview,
		PayloadType:    "guidance",
		Payload:        []byte(`{}`),
		DraftContent:   "Drink plenty of water and rest",
	})
	if err != nil {
		t.Fatalf("create recommendation: %v", err)
	}

	return carePhaseDeliveryFixture{tenant: tid, physician: phys, patient: patient, conv: conv, rec: rec}
}

// postCarePhaseReview submits action/final_content to the real handleReview
// handler with a physician session cookie.
func postCarePhaseReview(t *testing.T, h *web.Handler, tenant store.TenantID, physicianID, recID uuid.UUID, action, finalContent string) *httptest.ResponseRecorder {
	t.Helper()
	form := url.Values{"action": {action}}
	if finalContent != "" {
		form.Set("final_content", finalContent)
	}
	req := httptest.NewRequest("POST",
		"/web/recommendations/"+recID.String()+"/review",
		strings.NewReader(form.Encode()),
	)
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	req.AddCookie(makeCookie(t, tenant, physicianID, "physician"))
	rec := httptest.NewRecorder()
	r := chi.NewRouter()
	h.Mount(r)
	r.ServeHTTP(rec, req)
	return rec
}

// TestReview_Approve_MovesCarePhaseToPlanDelivered drives an approve through
// the real web handler and asserts the conversation lands on PLAN_DELIVERED
// in the same commit as the DELIVERED recommendation write.
func TestReview_Approve_MovesCarePhaseToPlanDelivered(t *testing.T) {
	pool := carePhaseTestPool(t)
	s := store.New(pool)
	h, err := web.New(s, testSecret, audit.New(s), nil)
	if err != nil {
		t.Fatalf("web.New: %v", err)
	}
	fx := seedCarePhaseDeliveryFixture(t, s)

	resp := postCarePhaseReview(t, h, fx.tenant, fx.physician.ID, fx.rec.ID, domain.ActionApprove, "")
	if resp.Code != 303 {
		t.Fatalf("approve: want 303, got %d (body: %s)", resp.Code, resp.Body.String())
	}

	updatedRec, err := s.GetRecommendation(context.Background(), fx.tenant, fx.rec.ID)
	if err != nil {
		t.Fatalf("get recommendation: %v", err)
	}
	if updatedRec.State != domain.StateDelivered {
		t.Fatalf("recommendation state = %q, want DELIVERED", updatedRec.State)
	}

	conv, err := s.GetConversation(context.Background(), fx.tenant, fx.conv.ID)
	if err != nil {
		t.Fatalf("get conversation: %v", err)
	}
	if conv.CarePhase != store.CarePhasePlanDelivered {
		t.Fatalf("care_phase = %q, want PLAN_DELIVERED", conv.CarePhase)
	}
}

// TestReview_Modify_MovesCarePhaseToPlanDelivered mirrors the approve test
// for the modify path, which also reaches DELIVERED.
func TestReview_Modify_MovesCarePhaseToPlanDelivered(t *testing.T) {
	pool := carePhaseTestPool(t)
	s := store.New(pool)
	h, err := web.New(s, testSecret, audit.New(s), nil)
	if err != nil {
		t.Fatalf("web.New: %v", err)
	}
	fx := seedCarePhaseDeliveryFixture(t, s)

	resp := postCarePhaseReview(t, h, fx.tenant, fx.physician.ID, fx.rec.ID, domain.ActionModify, "Take ibuprofen 400mg twice daily")
	if resp.Code != 303 {
		t.Fatalf("modify: want 303, got %d (body: %s)", resp.Code, resp.Body.String())
	}

	conv, err := s.GetConversation(context.Background(), fx.tenant, fx.conv.ID)
	if err != nil {
		t.Fatalf("get conversation: %v", err)
	}
	if conv.CarePhase != store.CarePhasePlanDelivered {
		t.Fatalf("care_phase = %q, want PLAN_DELIVERED", conv.CarePhase)
	}
}

// TestReview_Reject_DoesNotChangeCarePhase verifies that a rejection — which
// never reaches DELIVERED — leaves the conversation in AWAITING_REVIEW.
// Phase 3 owns the AWAITING_REVIEW -> INTAKE transition on rejection; this
// task must not touch care_phase for the reject path.
func TestReview_Reject_DoesNotChangeCarePhase(t *testing.T) {
	pool := carePhaseTestPool(t)
	s := store.New(pool)
	h, err := web.New(s, testSecret, audit.New(s), nil)
	if err != nil {
		t.Fatalf("web.New: %v", err)
	}
	fx := seedCarePhaseDeliveryFixture(t, s)

	resp := postCarePhaseReview(t, h, fx.tenant, fx.physician.ID, fx.rec.ID, domain.ActionReject, "")
	if resp.Code != 303 {
		t.Fatalf("reject: want 303, got %d (body: %s)", resp.Code, resp.Body.String())
	}

	updatedRec, err := s.GetRecommendation(context.Background(), fx.tenant, fx.rec.ID)
	if err != nil {
		t.Fatalf("get recommendation: %v", err)
	}
	if updatedRec.State != domain.StateRejected {
		t.Fatalf("recommendation state = %q, want REJECTED", updatedRec.State)
	}

	conv, err := s.GetConversation(context.Background(), fx.tenant, fx.conv.ID)
	if err != nil {
		t.Fatalf("get conversation: %v", err)
	}
	if conv.CarePhase != store.CarePhaseAwaitingReview {
		t.Fatalf("care_phase = %q, want unchanged AWAITING_REVIEW", conv.CarePhase)
	}
}
