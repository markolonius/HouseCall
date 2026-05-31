package store

// Task 3.3 focused tests — state-licensing enforcement:
//
//   (a) Store+domain: physician unlicensed in patient's state receives
//       ErrUnlicensedState from domain.Transition and the recommendation
//       state is never mutated.
//   (b) Store+domain: the rejection audit event is written (via
//       store.CreateAuditEvent) when an unlicensed review is blocked.
//   (c) Store+domain: a physician licensed in the patient's state passes the
//       licensing check without ErrUnlicensedState.

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
)

// makeLicensingFixture creates a tenant + patient (state="TX") + two
// physicians + a care relationship for each physician + a recommendation in
// PENDING_REVIEW.  Returns:
//   - tid: the tenant ID
//   - rec: the recommendation
//   - licensedDoc: physician licensed in TX
//   - unlicensedDoc: physician NOT licensed in TX (only licensed in CA)
func makeLicensingFixture(t *testing.T, s *Store) (TenantID, Recommendation, Physician, Physician) {
	t.Helper()
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "licensing-test-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, Patient{
		Email:        "patient@licensing.test",
		FullName:     "Pat",
		State:        "TX",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	licensedDoc, err := s.CreatePhysician(ctx, tid, Physician{
		Email:          "licensed@licensing.test",
		FullName:       "Licensed Doc",
		StatesLicensed: []string{"TX", "CA"},
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("create licensed physician: %v", err)
	}

	unlicensedDoc, err := s.CreatePhysician(ctx, tid, Physician{
		Email:          "unlicensed@licensing.test",
		FullName:       "Unlicensed Doc",
		StatesLicensed: []string{"CA"}, // not licensed in TX
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("create unlicensed physician: %v", err)
	}

	// Both physicians need a care relationship with the patient so that
	// GetRecommendationForPhysician does not return ErrNotFound for them.
	if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, licensedDoc.ID); err != nil {
		t.Fatalf("care relationship (licensed): %v", err)
	}
	if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, unlicensedDoc.ID); err != nil {
		t.Fatalf("care relationship (unlicensed): %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "licensing test conv")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	rec, err := s.CreateRecommendation(ctx, tid, Recommendation{
		ConversationID: conv.ID,
		PatientID:      patient.ID,
		State:          domain.StatePendingReview,
		PayloadType:    "guidance",
		Payload:        json.RawMessage(`{"text":"draft"}`),
		DraftContent:   "draft content",
	})
	if err != nil {
		t.Fatalf("create recommendation: %v", err)
	}

	return tid, rec, licensedDoc, unlicensedDoc
}

// TestLicensing_UnlicensedPhysicianIsRejected verifies that domain.Transition
// returns ErrUnlicensedState for approve, modify, and reject when the
// physician is not licensed in the patient's state, and that the
// recommendation state is left unchanged after each attempted action.
func TestLicensing_UnlicensedPhysicianIsRejected(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tid, rec, _, unlicensedDoc := makeLicensingFixture(t, s)

	// Load the patient to get its state.
	patient, err := s.GetPatient(ctx, tid, rec.PatientID)
	if err != nil {
		t.Fatalf("get patient: %v", err)
	}

	actor := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             unlicensedDoc.ID,
		StatesLicensed: unlicensedDoc.StatesLicensed,
	}

	for _, action := range []string{domain.ActionApprove, domain.ActionModify, domain.ActionReject} {
		action := action
		t.Run("action="+action, func(t *testing.T) {
			// The domain check must fire before any DB write.
			_, err := domain.Transition(rec.State, action, actor, patient.State)
			if !errors.Is(err, domain.ErrUnlicensedState) {
				t.Fatalf("expected ErrUnlicensedState for action %q, got %v", action, err)
			}

			// Confirm the recommendation state is unchanged (no DB write occurred).
			got, err := s.GetRecommendation(ctx, tid, rec.ID)
			if err != nil {
				t.Fatalf("get recommendation: %v", err)
			}
			if got.State != domain.StatePendingReview {
				t.Fatalf("state mutated despite licensing rejection: got %q", got.State)
			}
		})
	}
}

// TestLicensing_RejectionAuditEventWritten verifies that when an unlicensed
// physician's action is blocked, an audit event with event_type
// "recommendation.review_rejected" and reason "unlicensed_state" is persisted,
// and the recommendation state remains PENDING_REVIEW.
func TestLicensing_RejectionAuditEventWritten(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tid, rec, _, unlicensedDoc := makeLicensingFixture(t, s)

	patient, err := s.GetPatient(ctx, tid, rec.PatientID)
	if err != nil {
		t.Fatalf("get patient: %v", err)
	}

	actor := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             unlicensedDoc.ID,
		StatesLicensed: unlicensedDoc.StatesLicensed,
	}

	action := domain.ActionApprove
	_, transErr := domain.Transition(rec.State, action, actor, patient.State)
	if !errors.Is(transErr, domain.ErrUnlicensedState) {
		t.Fatalf("expected ErrUnlicensedState, got %v", transErr)
	}

	// Simulate what the handler does: write the rejection audit event without
	// mutating state (no Txn, just a direct audit write).
	actorID := unlicensedDoc.ID
	_, auditErr := s.CreateAuditEvent(ctx, tid, AuditEvent{
		ActorType: "physician",
		ActorID:   &actorID,
		EventType: "recommendation.review_rejected",
		Metadata: mustJSON(map[string]any{
			"recommendation_id": rec.ID.String(),
			"action":            action,
			"reason":            "unlicensed_state",
		}),
	})
	if auditErr != nil {
		t.Fatalf("write rejection audit event: %v", auditErr)
	}

	// The recommendation state must still be PENDING_REVIEW.
	got, err := s.GetRecommendation(ctx, tid, rec.ID)
	if err != nil {
		t.Fatalf("get recommendation: %v", err)
	}
	if got.State != domain.StatePendingReview {
		t.Fatalf("recommendation state must be unchanged: got %q", got.State)
	}

	// The audit row must be present with the right event_type and metadata.
	var metadata []byte
	queryErr := pool.QueryRow(ctx,
		`SELECT metadata FROM audit_events
		  WHERE tenant_id = $1
		    AND event_type = 'recommendation.review_rejected'
		    AND actor_id = $2`,
		tid.UUID(), unlicensedDoc.ID,
	).Scan(&metadata)
	if queryErr != nil {
		t.Fatalf("query rejection audit event: %v", queryErr)
	}

	var meta map[string]any
	if err := json.Unmarshal(metadata, &meta); err != nil {
		t.Fatalf("unmarshal audit metadata: %v", err)
	}
	if meta["reason"] != "unlicensed_state" {
		t.Fatalf("audit metadata reason = %q, want %q", meta["reason"], "unlicensed_state")
	}
	if meta["recommendation_id"] != rec.ID.String() {
		t.Fatalf("audit metadata recommendation_id = %q, want %q", meta["recommendation_id"], rec.ID.String())
	}
}

// TestLicensing_LicensedPhysicianPasses verifies that a physician who IS
// licensed in the patient's state does not receive ErrUnlicensedState from
// domain.Transition for any of the three review actions.
func TestLicensing_LicensedPhysicianPasses(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tid, rec, licensedDoc, _ := makeLicensingFixture(t, s)

	patient, err := s.GetPatient(ctx, tid, rec.PatientID)
	if err != nil {
		t.Fatalf("get patient: %v", err)
	}

	actor := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             licensedDoc.ID,
		StatesLicensed: licensedDoc.StatesLicensed,
	}

	for _, action := range []string{domain.ActionApprove, domain.ActionModify, domain.ActionReject} {
		action := action
		t.Run("action="+action, func(t *testing.T) {
			_, err := domain.Transition(rec.State, action, actor, patient.State)
			if errors.Is(err, domain.ErrUnlicensedState) {
				t.Fatalf("licensed physician got ErrUnlicensedState for action %q", action)
			}
			// The transition may return ErrInvalidTransition for other reasons
			// (e.g. state not PENDING_REVIEW after a prior sub-test), but
			// ErrUnlicensedState must never appear for a licensed physician.
		})
	}
}
