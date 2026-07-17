package store

// Task 3.3 — GetLatestRejectionReason: the read-only query the agent drafter
// uses to decide whether an INTAKE interview turn should carry reviewer
// guidance from a physician's rejection. See
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Rejection Revision Loop".

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/markolonius/housecall/backend/internal/domain"
)

// rgSetReviewed creates a recommendation in the given state and, via a raw
// UPDATE, stamps reviewed_at and rejection_reason directly — CreateRecommendation
// has no parameters for either, and production code only ever sets them
// through UpdateRecommendationRejection/UpdateRecommendationState. Driving
// timestamps directly lets the test control ordering between rows precisely.
func rgSetReviewed(t *testing.T, s *Store, pool *pgxpool.Pool, tid TenantID, convID, patientID uuid.UUID, state string, reason *string, reviewedAt time.Time) Recommendation {
	t.Helper()
	ctx := context.Background()

	rec, err := s.CreateRecommendation(ctx, tid, Recommendation{
		ConversationID: convID,
		PatientID:      patientID,
		State:          state,
		PayloadType:    "guidance",
		Payload:        json.RawMessage(`{"text":"x"}`),
		DraftContent:   "draft",
	})
	if err != nil {
		t.Fatalf("create recommendation: %v", err)
	}

	if _, err := pool.Exec(ctx,
		`UPDATE recommendations SET reviewed_at = $3, rejection_reason = $4
		  WHERE tenant_id = $1 AND id = $2`,
		tid.UUID(), rec.ID, reviewedAt, reason,
	); err != nil {
		t.Fatalf("stamp reviewed_at/rejection_reason: %v", err)
	}
	return rec
}

// TestGetLatestRejectionReason_NoRecommendations verifies a conversation with
// no recommendations at all returns ok == false.
func TestGetLatestRejectionReason_NoRecommendations(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s) // fixture's default recommendation is PENDING_REVIEW, not REJECTED
	ctx := context.Background()

	reason, ok, err := s.GetLatestRejectionReason(ctx, TenantID(f.A.Tenant.ID), f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestRejectionReason: %v", err)
	}
	if ok {
		t.Errorf("ok = true, reason = %q, want false (no rejection present)", reason)
	}
}

// TestGetLatestRejectionReason_CurrentRejection verifies a single REJECTED
// recommendation is surfaced.
func TestGetLatestRejectionReason_CurrentRejection(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()
	tid := TenantID(f.A.Tenant.ID)

	want := "ask about current medications"
	rgSetReviewed(t, s, pool, tid, f.A.Conversation.ID, f.A.Patient.ID,
		domain.StateRejected, &want, time.Now())

	reason, ok, err := s.GetLatestRejectionReason(ctx, tid, f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestRejectionReason: %v", err)
	}
	if !ok {
		t.Fatal("ok = false, want true")
	}
	if reason != want {
		t.Errorf("reason = %q, want %q", reason, want)
	}
}

// TestGetLatestRejectionReason_StaleAfterDelivery verifies that a rejection
// followed by a LATER delivery (the plan was subsequently approved/modified
// and delivered) is no longer surfaced — the old rejection is stale.
func TestGetLatestRejectionReason_StaleAfterDelivery(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()
	tid := TenantID(f.A.Tenant.ID)

	older := time.Now().Add(-time.Hour)
	newer := time.Now()

	reason := "ask about current medications"
	rgSetReviewed(t, s, pool, tid, f.A.Conversation.ID, f.A.Patient.ID,
		domain.StateRejected, &reason, older)
	rgSetReviewed(t, s, pool, tid, f.A.Conversation.ID, f.A.Patient.ID,
		domain.StateDelivered, nil, newer)

	got, ok, err := s.GetLatestRejectionReason(ctx, tid, f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestRejectionReason: %v", err)
	}
	if ok {
		t.Errorf("ok = true, reason = %q, want false (delivery is newer than the rejection)", got)
	}
}

// TestGetLatestRejectionReason_CurrentAfterOlderDelivery verifies that a
// rejection newer than an earlier delivery IS surfaced — e.g. the patient's
// plan was delivered once, a new complaint reopened INTAKE, a fresh draft was
// produced and rejected. The most recent reviewed outcome (rejection) governs.
func TestGetLatestRejectionReason_CurrentAfterOlderDelivery(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()
	tid := TenantID(f.A.Tenant.ID)

	older := time.Now().Add(-time.Hour)
	newer := time.Now()

	rgSetReviewed(t, s, pool, tid, f.A.Conversation.ID, f.A.Patient.ID,
		domain.StateDelivered, nil, older)
	want := "clarify symptom duration"
	rgSetReviewed(t, s, pool, tid, f.A.Conversation.ID, f.A.Patient.ID,
		domain.StateRejected, &want, newer)

	reason, ok, err := s.GetLatestRejectionReason(ctx, tid, f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestRejectionReason: %v", err)
	}
	if !ok {
		t.Fatal("ok = false, want true (rejection is newer than the delivery)")
	}
	if reason != want {
		t.Errorf("reason = %q, want %q", reason, want)
	}
}

// TestGetLatestRejectionReason_PicksMostRecentRejection verifies that when
// multiple REJECTED recommendations exist for the same conversation, the
// most recently reviewed one's reason is returned.
func TestGetLatestRejectionReason_PicksMostRecentRejection(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()
	tid := TenantID(f.A.Tenant.ID)

	older := time.Now().Add(-time.Hour)
	newer := time.Now()

	stale := "ask about allergies"
	rgSetReviewed(t, s, pool, tid, f.A.Conversation.ID, f.A.Patient.ID,
		domain.StateRejected, &stale, older)
	want := "ask about current medications"
	rgSetReviewed(t, s, pool, tid, f.A.Conversation.ID, f.A.Patient.ID,
		domain.StateRejected, &want, newer)

	reason, ok, err := s.GetLatestRejectionReason(ctx, tid, f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestRejectionReason: %v", err)
	}
	if !ok {
		t.Fatal("ok = false, want true")
	}
	if reason != want {
		t.Errorf("reason = %q, want %q", reason, want)
	}
}

// TestGetLatestRejectionReason_TenantIsolation verifies a rejection in
// tenant B never surfaces for tenant A's conversation, even when both
// tenants' conversation rows share no overlap by construction (defence in
// depth for the tenant_id predicate).
func TestGetLatestRejectionReason_TenantIsolation(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	reason := "tenant B only"
	rgSetReviewed(t, s, pool, TenantID(f.B.Tenant.ID), f.B.Conversation.ID, f.B.Patient.ID,
		domain.StateRejected, &reason, time.Now())

	got, ok, err := s.GetLatestRejectionReason(ctx, TenantID(f.A.Tenant.ID), f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("GetLatestRejectionReason: %v", err)
	}
	if ok {
		t.Errorf("tenant A query returned tenant B's rejection: ok = true, reason = %q", got)
	}
}
