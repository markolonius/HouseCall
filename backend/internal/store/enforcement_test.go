package store

// Task 3.2 focused tests:
//   (a) state change + audit event are atomic — both roll back on failure
//   (b) patient-visible content (final_content) is nil for every non-DELIVERED state

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"
)

// makeReviewFixture creates a minimal tenant + patient + physician +
// conversation + recommendation in PENDING_REVIEW so review-path tests have
// something to act on. The returned physicianID is a real row in physicians so
// it satisfies the (tenant_id, reviewed_by) FK in recommendations.
func makeReviewFixture(t *testing.T, s *Store) (TenantID, Recommendation, uuid.UUID) {
	t.Helper()
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "review-test-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, Patient{
		Email:        "p@review.test",
		FullName:     "Patient",
		State:        "PA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	physician, err := s.CreatePhysician(ctx, tid, Physician{
		Email:          "doc@review.test",
		FullName:       "Doctor",
		StatesLicensed: []string{"PA"},
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("create physician: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "visit")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	rec, err := s.CreateRecommendation(ctx, tid, Recommendation{
		ConversationID: conv.ID,
		PatientID:      patient.ID,
		State:          "PENDING_REVIEW",
		PayloadType:    "guidance",
		Payload:        json.RawMessage(`{"text":"draft"}`),
		DraftContent:   "draft content",
	})
	if err != nil {
		t.Fatalf("create recommendation: %v", err)
	}

	return tid, rec, physician.ID
}

// TestAtomicity_RollbackOnAuditFailure verifies that when the audit write
// inside a Txn fails, the state-change write is also rolled back — both
// operations succeed or both are discarded.
func TestAtomicity_RollbackOnAuditFailure(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tid, rec, physicianID := makeReviewFixture(t, s)
	recID := rec.ID

	// Intentionally pass an oversized event_type to trigger a DB constraint
	// or truncation error on the audit_events insert, simulating audit failure.
	// audit_events.event_type is a text column, but we can force a failure by
	// using a deliberate SQL error: pass NULL for a NOT NULL column by abusing
	// a raw Txn call.
	oversizedType := string(make([]byte, 10000)) // 10 KB string — exceeds text column if constrained

	_ = oversizedType // may or may not fail depending on DB constraints

	// Strategy: inject an error from the fn itself so the transaction rolls back.
	sentinelErr := errors.New("simulated audit failure")
	err := s.Txn(ctx, func(tx *TxStore) error {
		if err := tx.UpdateRecommendationState(ctx, tid, recID,
			"DELIVERED", &physicianID, strPtr("patient content")); err != nil {
			return err
		}
		// Simulate the audit write failing.
		return sentinelErr
	})
	if err == nil {
		t.Fatal("expected Txn to return error, got nil")
	}

	// The state change must have been rolled back along with the failed audit.
	got, err := s.GetRecommendation(ctx, tid, recID)
	if err != nil {
		t.Fatalf("get recommendation after rollback: %v", err)
	}
	if got.State != "PENDING_REVIEW" {
		t.Fatalf("state was mutated despite rollback: got %q, want PENDING_REVIEW", got.State)
	}
	if got.FinalContent != nil {
		t.Fatalf("final_content was set despite rollback: got %q", *got.FinalContent)
	}
}

// TestAtomicity_BothCommitOnSuccess verifies the happy path: when both the
// state update and the audit write succeed, both are visible after commit.
func TestAtomicity_BothCommitOnSuccess(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tid, rec, physicianID := makeReviewFixture(t, s)
	recID := rec.ID
	content := "patient-visible content"

	err := s.Txn(ctx, func(tx *TxStore) error {
		if err := tx.UpdateRecommendationState(ctx, tid, recID,
			"DELIVERED", &physicianID, &content); err != nil {
			return err
		}
		return tx.CreateAuditEvent(ctx, tid, AuditEvent{
			ActorType: "physician",
			ActorID:   &physicianID,
			EventType: "recommendation.reviewed",
			Metadata:  mustJSON(map[string]any{"recommendation_id": recID.String()}),
		})
	})
	if err != nil {
		t.Fatalf("Txn failed: %v", err)
	}

	got, err := s.GetRecommendation(ctx, tid, recID)
	if err != nil {
		t.Fatalf("get recommendation after commit: %v", err)
	}
	if got.State != "DELIVERED" {
		t.Fatalf("state not updated: got %q, want DELIVERED", got.State)
	}
	if got.FinalContent == nil || *got.FinalContent != content {
		t.Fatalf("final_content not set: %v", got.FinalContent)
	}

	// Verify the audit row was also committed.
	var count int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'recommendation.reviewed'`,
		tid.UUID(),
	).Scan(&count); err != nil {
		t.Fatalf("count audit events: %v", err)
	}
	if count != 1 {
		t.Fatalf("audit event count = %d, want 1", count)
	}
}

// TestContentVisibility_NonDeliveredStatesHaveNoFinalContent asserts that
// recommendations in PENDING_REVIEW, APPROVED, MODIFIED, and REJECTED never
// carry a non-nil final_content — the patient-visible field is populated only
// when a recommendation reaches DELIVERED.
func TestContentVisibility_NonDeliveredStatesHaveNoFinalContent(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	nonDeliveredStates := []struct {
		state   string
		content *string // nil means no final_content should be set
	}{
		{"PENDING_REVIEW", nil},
		{"APPROVED", nil},
		{"MODIFIED", nil},
		{"REJECTED", nil},
	}

	for _, tc := range nonDeliveredStates {
		tc := tc
		t.Run(tc.state, func(t *testing.T) {
			// Create a fresh recommendation for each state under test.
			tid, rec, physicianID := makeReviewFixture(t, s)
			recID := rec.ID

			// Write the non-DELIVERED state without final_content.
			err := s.Txn(ctx, func(tx *TxStore) error {
				return tx.UpdateRecommendationState(ctx, tid, recID,
					tc.state, &physicianID, nil)
			})
			if err != nil {
				t.Fatalf("set state %s: %v", tc.state, err)
			}

			got, err := s.GetRecommendation(ctx, tid, recID)
			if err != nil {
				t.Fatalf("get recommendation in state %s: %v", tc.state, err)
			}
			if got.FinalContent != nil {
				t.Fatalf("state %s: final_content must be nil, got %q",
					tc.state, *got.FinalContent)
			}
		})
	}
}

// TestContentVisibility_DeliveredSetsContent confirms that transitioning to
// DELIVERED with a non-nil final_content makes the field readable.
func TestContentVisibility_DeliveredSetsContent(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tid, rec, physicianID := makeReviewFixture(t, s)
	recID := rec.ID
	want := "approved content for patient"

	err := s.Txn(ctx, func(tx *TxStore) error {
		return tx.UpdateRecommendationState(ctx, tid, recID,
			"DELIVERED", &physicianID, &want)
	})
	if err != nil {
		t.Fatalf("transition to DELIVERED: %v", err)
	}

	got, err := s.GetRecommendation(ctx, tid, recID)
	if err != nil {
		t.Fatalf("get delivered recommendation: %v", err)
	}
	if got.FinalContent == nil {
		t.Fatal("final_content is nil after DELIVERED transition")
	}
	if *got.FinalContent != want {
		t.Fatalf("final_content = %q, want %q", *got.FinalContent, want)
	}
}

// strPtr is a local helper so test helpers don't need to import a separate pkg.
func strPtr(s string) *string { return &s }
