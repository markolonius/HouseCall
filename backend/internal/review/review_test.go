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
	return fn(&noopTxWriter{})
}

// noopTxWriter satisfies store.TxWriter for tests that only need TxnW to succeed.
type noopTxWriter struct{}

func (n *noopTxWriter) UpdateRecommendationState(_ context.Context, _ store.TenantID, _ uuid.UUID, _ string, _ *uuid.UUID, _ *string) error {
	return nil
}
func (n *noopTxWriter) CreateAuditEvent(_ context.Context, _ store.TenantID, _ store.AuditEvent) error {
	return nil
}

// ---- tests ---------------------------------------------------------------------

var (
	testTenant    = store.TenantID(uuid.MustParse("aaaaaaaa-0000-0000-0000-000000000001"))
	testPhysicianID = uuid.MustParse("bbbbbbbb-0000-0000-0000-000000000002")
	testPatientID   = uuid.MustParse("cccccccc-0000-0000-0000-000000000003")
	testRecID       = uuid.MustParse("dddddddd-0000-0000-0000-000000000004")
)

// TestExecute_RecommendationNotFound verifies that when the care-relationship
// scoped query returns ErrNotFound, Execute propagates store.ErrNotFound — the
// transport should map this to 404.
func TestExecute_RecommendationNotFound(t *testing.T) {
	s := &reviewFakeStore{rec: nil} // rec not found

	_, err := review.Execute(context.Background(), s, testTenant,
		testPhysicianID, testRecID, domain.ActionApprove, "")
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
		testPhysicianID, testRecID, domain.ActionApprove, "")
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
		ID:           testRecID,
		TenantID:     testTenant,
		PatientID:    testPatientID,
		State:        domain.StatePendingReview,
		DraftContent: "drink water",
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
		testPhysicianID, testRecID, domain.ActionApprove, "")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.FinalState != domain.StateDelivered {
		t.Fatalf("want DELIVERED, got %q", result.FinalState)
	}
}
