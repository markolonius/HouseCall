package review_test

// review_test.go — unit tests for Execute using a fake store (no DB required).
//
// Covered:
//   - TestExecute_PhysicianNotFound: Execute returns ErrActorNotFound (not
//     store.ErrNotFound) when GetPhysician returns ErrNotFound, so API and web
//     transports can map it to 403 rather than 404.
//   - TestExecute_RecommendationNotFound: Execute returns store.ErrNotFound
//     when GetRecommendationForPhysician returns ErrNotFound (→ 404).

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/review"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ---- fake store ----------------------------------------------------------------

// reviewFakeStore is a minimal fake that satisfies review.Store.
type reviewFakeStore struct {
	rec     *store.Recommendation // nil → GetRecommendationForPhysician returns ErrNotFound
	phys    *store.Physician      // nil → GetPhysician returns ErrNotFound
	patient *store.Patient        // nil → GetPatient returns ErrNotFound

	// carePhaseErr, when non-nil, is returned by every TransitionCarePhase
	// call the fake TxWriter makes — used to simulate a CAS miss
	// (store.ErrNotFound) or an unexpected DB error.
	carePhaseErr error
	// carePhaseCalls records every TransitionCarePhase invocation so tests
	// can assert it was (or wasn't) called, and with which from/to.
	carePhaseCalls []carePhaseCall
	// auditEvents records every audit event written inside the transaction
	// (including the recommendation.delivered_phase_mismatch and
	// recommendation.rejected_phase_mismatch events).
	auditEvents []store.AuditEvent
	// rejectionCalls records every UpdateRecommendationRejection invocation so
	// tests can assert the stored reason.
	rejectionCalls []rejectionCall
}

type carePhaseCall struct {
	conversationID uuid.UUID
	from, to       store.CarePhase
}

type rejectionCall struct {
	id         uuid.UUID
	reviewedBy uuid.UUID
	reason     string
}

func (f *reviewFakeStore) GetRecommendationForPhysician(_ context.Context, _ store.TenantID, _, _ uuid.UUID) (store.Recommendation, error) {
	if f.rec == nil {
		return store.Recommendation{}, store.ErrNotFound
	}
	return *f.rec, nil
}

func (f *reviewFakeStore) GetPhysician(_ context.Context, _ store.TenantID, _ uuid.UUID) (store.Physician, error) {
	if f.phys == nil {
		return store.Physician{}, store.ErrNotFound
	}
	return *f.phys, nil
}

func (f *reviewFakeStore) GetPatient(_ context.Context, _ store.TenantID, _ uuid.UUID) (store.Patient, error) {
	if f.patient == nil {
		return store.Patient{}, store.ErrNotFound
	}
	return *f.patient, nil
}

func (f *reviewFakeStore) CreateAuditEvent(_ context.Context, _ store.TenantID, e store.AuditEvent) (store.AuditEvent, error) {
	return e, nil
}

func (f *reviewFakeStore) TxnW(_ context.Context, fn func(store.TxWriter) error) error {
	return fn(&noopTxWriter{f: f})
}

// noopTxWriter satisfies store.TxWriter for tests that only need TxnW to
// succeed. TransitionCarePhase and CreateAuditEvent are recorded on the
// owning reviewFakeStore so tests can assert on them.
type noopTxWriter struct{ f *reviewFakeStore }

func (n *noopTxWriter) UpdateRecommendationState(_ context.Context, _ store.TenantID, _ uuid.UUID, _ string, _ *uuid.UUID, _ *string) error {
	return nil
}
func (n *noopTxWriter) UpdateRecommendationRejection(_ context.Context, _ store.TenantID, id uuid.UUID, reviewedBy uuid.UUID, reason string) error {
	if n.f != nil {
		n.f.rejectionCalls = append(n.f.rejectionCalls, rejectionCall{id: id, reviewedBy: reviewedBy, reason: reason})
	}
	return nil
}
func (n *noopTxWriter) CreateAuditEvent(_ context.Context, _ store.TenantID, e store.AuditEvent) error {
	if n.f != nil {
		n.f.auditEvents = append(n.f.auditEvents, e)
	}
	return nil
}
func (n *noopTxWriter) TransitionCarePhase(_ context.Context, _ store.TenantID, conversationID uuid.UUID, from, to store.CarePhase) error {
	if n.f != nil {
		n.f.carePhaseCalls = append(n.f.carePhaseCalls, carePhaseCall{conversationID: conversationID, from: from, to: to})
		return n.f.carePhaseErr
	}
	return nil
}

// ---- tests ---------------------------------------------------------------------

var (
	testTenant      = store.TenantID(uuid.MustParse("aaaaaaaa-0000-0000-0000-000000000001"))
	testPhysicianID = uuid.MustParse("bbbbbbbb-0000-0000-0000-000000000002")
	testPatientID   = uuid.MustParse("cccccccc-0000-0000-0000-000000000003")
	testRecID       = uuid.MustParse("dddddddd-0000-0000-0000-000000000004")
	testConvID      = uuid.MustParse("eeeeeeee-0000-0000-0000-000000000005")
)

// TestExecute_RecommendationNotFound verifies that when the care-relationship
// scoped query returns ErrNotFound, Execute propagates store.ErrNotFound — the
// transport should map this to 404.
func TestExecute_RecommendationNotFound(t *testing.T) {
	s := &reviewFakeStore{rec: nil} // rec not found

	_, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionApprove, "", "")
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("want store.ErrNotFound, got %v", err)
	}
	// Must NOT be ErrActorNotFound — that's reserved for physician-not-found.
	if errors.Is(err, review.ErrActorNotFound) {
		t.Fatal("rec-not-found must not return ErrActorNotFound")
	}
}

// TestExecute_PhysicianNotFound verifies that when GetPhysician returns
// ErrNotFound (session actor no longer in DB), Execute returns
// review.ErrActorNotFound — NOT store.ErrNotFound — so transports can
// distinguish the two cases and map physician-not-found to 403 (not 404).
func TestExecute_PhysicianNotFound(t *testing.T) {
	rec := &store.Recommendation{
		ID:           testRecID,
		TenantID:     testTenant,
		PatientID:    testPatientID,
		State:        domain.StatePendingReview,
		DraftContent: "some draft",
	}
	// Physician is nil → GetPhysician returns ErrNotFound.
	s := &reviewFakeStore{rec: rec, phys: nil}

	_, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionApprove, "", "")
	if !errors.Is(err, review.ErrActorNotFound) {
		t.Fatalf("want review.ErrActorNotFound, got %v", err)
	}
	// Must NOT be plain store.ErrNotFound — that would cause 404 mapping.
	if errors.Is(err, store.ErrNotFound) {
		t.Fatal("physician-not-found must not return bare store.ErrNotFound (would map to 404)")
	}
}

// TestExecute_ApproveDelivers verifies the happy-path: approve transitions
// PENDING_REVIEW → DELIVERED when the physician is licensed in the patient's state.
func TestExecute_ApproveDelivers(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient}

	result, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionApprove, "", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.FinalState != domain.StateDelivered {
		t.Fatalf("want DELIVERED, got %q", result.FinalState)
	}

	// The care-phase move must be part of the same transaction as the
	// DELIVERED write (task 2.4).
	if len(s.carePhaseCalls) != 1 {
		t.Fatalf("want exactly 1 TransitionCarePhase call, got %d", len(s.carePhaseCalls))
	}
	call := s.carePhaseCalls[0]
	if call.conversationID != testConvID {
		t.Errorf("conversationID: want %s, got %s", testConvID, call.conversationID)
	}
	if call.from != store.CarePhaseAwaitingReview || call.to != store.CarePhasePlanDelivered {
		t.Errorf("transition: want AWAITING_REVIEW -> PLAN_DELIVERED, got %s -> %s", call.from, call.to)
	}
}

// TestExecute_ModifyDelivers_TransitionsCarePhase mirrors
// TestExecute_ApproveDelivers for the modify path, which also reaches
// DELIVERED and must move the conversation to PLAN_DELIVERED.
func TestExecute_ModifyDelivers_TransitionsCarePhase(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient}

	result, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionModify, "take ibuprofen", "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.FinalState != domain.StateDelivered {
		t.Fatalf("want DELIVERED, got %q", result.FinalState)
	}
	if len(s.carePhaseCalls) != 1 {
		t.Fatalf("want exactly 1 TransitionCarePhase call, got %d", len(s.carePhaseCalls))
	}
	if got := s.carePhaseCalls[0]; got.from != store.CarePhaseAwaitingReview || got.to != store.CarePhasePlanDelivered {
		t.Errorf("transition: want AWAITING_REVIEW -> PLAN_DELIVERED, got %s -> %s", got.from, got.to)
	}
}

// TestExecute_Reject_EmptyReasonRefused verifies that an empty (or
// whitespace-only) rejection reason is refused with review.ErrEmptyRejectionReason
// and that Execute makes NO store call at all — not even
// GetRecommendationForPhysician. rec is deliberately left nil (which would
// otherwise cause GetRecommendationForPhysician to return store.ErrNotFound)
// so a store.ErrNotFound result here would prove the validation ran too late.
func TestExecute_Reject_EmptyReasonRefused(t *testing.T) {
	for _, reason := range []string{"", "   ", "\t\n"} {
		s := &reviewFakeStore{} // rec/phys/patient all nil — must never be touched.

		_, err := review.Execute(context.Background(), s, testTenant,
			testPhysicianID, testRecID, domain.ActionReject, "", reason)
		if !errors.Is(err, review.ErrEmptyRejectionReason) {
			t.Fatalf("reason %q: want review.ErrEmptyRejectionReason, got %v", reason, err)
		}
		if len(s.rejectionCalls) != 0 || len(s.auditEvents) != 0 || len(s.carePhaseCalls) != 0 {
			t.Fatalf("reason %q: empty-reason rejection must not touch the store: rejectionCalls=%d auditEvents=%d carePhaseCalls=%d",
				reason, len(s.rejectionCalls), len(s.auditEvents), len(s.carePhaseCalls))
		}
	}
}

// TestExecute_RejectReasonStoredAndAudited verifies that a valid rejection
// stores the trimmed reason via UpdateRecommendationRejection and includes it
// in the recommendation.reviewed audit event's metadata, both within the same
// TxnW call.
func TestExecute_RejectReasonStoredAndAudited(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient}

	result, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionReject, "", "  ask about current medications  ")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.FinalState != domain.StateRejected {
		t.Fatalf("want REJECTED, got %q", result.FinalState)
	}

	if len(s.rejectionCalls) != 1 {
		t.Fatalf("want exactly 1 UpdateRecommendationRejection call, got %d", len(s.rejectionCalls))
	}
	rc := s.rejectionCalls[0]
	if rc.id != testRecID {
		t.Errorf("rejection call id: want %s, got %s", testRecID, rc.id)
	}
	if rc.reviewedBy != testPhysicianID {
		t.Errorf("rejection call reviewedBy: want %s, got %s", testPhysicianID, rc.reviewedBy)
	}
	const wantReason = "ask about current medications"
	if rc.reason != wantReason {
		t.Errorf("rejection call reason: want %q, got %q (must be trimmed)", wantReason, rc.reason)
	}

	found := false
	for _, e := range s.auditEvents {
		if e.EventType != "recommendation.reviewed" {
			continue
		}
		found = true
		var meta map[string]any
		if err := json.Unmarshal(e.Metadata, &meta); err != nil {
			t.Fatalf("unmarshal audit metadata: %v", err)
		}
		if meta["reason"] != wantReason {
			t.Errorf("audit metadata reason: want %q, got %v", wantReason, meta["reason"])
		}
		if meta["new_state"] != domain.StateRejected {
			t.Errorf("audit metadata new_state: want %q, got %v", domain.StateRejected, meta["new_state"])
		}
	}
	if !found {
		t.Fatal("want a recommendation.reviewed audit event")
	}
}

// TestExecute_RejectResetsCarePhase verifies that a rejection moves the
// conversation's care_phase AWAITING_REVIEW -> INTAKE in the same transaction
// as the REJECTED write (task 3.1 — Phase 2's delivery path owns
// AWAITING_REVIEW -> PLAN_DELIVERED; this is the mirror image for reject).
func TestExecute_RejectResetsCarePhase(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient}

	result, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionReject, "", "ask about current medications")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.FinalState != domain.StateRejected {
		t.Fatalf("want REJECTED, got %q", result.FinalState)
	}
	if len(s.carePhaseCalls) != 1 {
		t.Fatalf("want exactly 1 TransitionCarePhase call, got %d", len(s.carePhaseCalls))
	}
	call := s.carePhaseCalls[0]
	if call.conversationID != testConvID {
		t.Errorf("conversationID: want %s, got %s", testConvID, call.conversationID)
	}
	if call.from != store.CarePhaseAwaitingReview || call.to != store.CarePhaseIntake {
		t.Errorf("transition: want AWAITING_REVIEW -> INTAKE, got %s -> %s", call.from, call.to)
	}
}

// TestExecute_RejectTolerates_CarePhaseMismatch mirrors
// TestExecute_DeliverTolerates_CarePhaseMismatch for the reject path: when the
// conversation is not observed in AWAITING_REVIEW at rejection time
// (TransitionCarePhase returns store.ErrNotFound — a CAS miss), Execute does
// NOT fail the rejection. The recommendation still reaches REJECTED and a
// recommendation.rejected_phase_mismatch audit event records the mismatch.
func TestExecute_RejectTolerates_CarePhaseMismatch(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient, carePhaseErr: store.ErrNotFound}

	result, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionReject, "", "ask about current medications")
	if err != nil {
		t.Fatalf("rejection must not fail on a care-phase CAS miss: %v", err)
	}
	if result.FinalState != domain.StateRejected {
		t.Fatalf("want REJECTED despite the care-phase mismatch, got %q", result.FinalState)
	}

	found := false
	for _, e := range s.auditEvents {
		if e.EventType == "recommendation.rejected_phase_mismatch" {
			found = true
		}
	}
	if !found {
		t.Fatal("want a recommendation.rejected_phase_mismatch audit event")
	}
}

// TestExecute_RejectFails_OnUnexpectedCarePhaseError mirrors
// TestExecute_DeliverFails_OnUnexpectedCarePhaseError for the reject path:
// only the specific CAS-miss case is tolerated — any other TransitionCarePhase
// error fails the whole transaction.
func TestExecute_RejectFails_OnUnexpectedCarePhaseError(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	wantErr := errors.New("boom: connection reset")
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient, carePhaseErr: wantErr}

	_, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionReject, "", "ask about current medications")
	if !errors.Is(err, wantErr) {
		t.Fatalf("want %v, got %v", wantErr, err)
	}
}

// TestExecute_DeliverTolerates_CarePhaseMismatch verifies the deliberate
// tolerate-on-mismatch decision (task 2.4): when the conversation is not
// observed in AWAITING_REVIEW at delivery time (TransitionCarePhase returns
// store.ErrNotFound — a CAS miss), Execute does NOT fail the delivery. The
// recommendation still reaches DELIVERED and an audit event records the
// mismatch. Rationale: care_phase is agent-behaviour routing, not a gate on
// a physician's clinical decision — delivering physician-approved content
// must never be blocked by an internal phase-tracking inconsistency.
func TestExecute_DeliverTolerates_CarePhaseMismatch(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient, carePhaseErr: store.ErrNotFound}

	result, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionApprove, "", "")
	if err != nil {
		t.Fatalf("delivery must not fail on a care-phase CAS miss: %v", err)
	}
	if result.FinalState != domain.StateDelivered {
		t.Fatalf("want DELIVERED despite the care-phase mismatch, got %q", result.FinalState)
	}

	found := false
	for _, e := range s.auditEvents {
		if e.EventType == "recommendation.delivered_phase_mismatch" {
			found = true
		}
	}
	if !found {
		t.Fatal("want a recommendation.delivered_phase_mismatch audit event")
	}
}

// TestExecute_DeliverFails_OnUnexpectedCarePhaseError verifies that a
// TransitionCarePhase error OTHER than store.ErrNotFound (e.g. a real DB
// error) fails the whole transaction — only the specific CAS-miss case is
// tolerated.
func TestExecute_DeliverFails_OnUnexpectedCarePhaseError(t *testing.T) {
	rec := &store.Recommendation{
		ID:             testRecID,
		TenantID:       testTenant,
		ConversationID: testConvID,
		PatientID:      testPatientID,
		State:          domain.StatePendingReview,
		DraftContent:   "drink water",
	}
	phys := &store.Physician{
		ID:             testPhysicianID,
		TenantID:       testTenant,
		StatesLicensed: []string{"CA"},
	}
	patient := &store.Patient{
		ID:       testPatientID,
		TenantID: testTenant,
		State:    "CA",
	}
	wantErr := errors.New("boom: connection reset")
	s := &reviewFakeStore{rec: rec, phys: phys, patient: patient, carePhaseErr: wantErr}

	_, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionApprove, "", "")
	if !errors.Is(err, wantErr) {
		t.Fatalf("want %v, got %v", wantErr, err)
	}
}
