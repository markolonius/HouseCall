// Package review contains the transport-agnostic physician review flow.
// It is shared by the JSON API (internal/api) and the server-rendered web app
// (internal/web) so both surfaces drive the same domain.Transition + store.TxnW
// path and cannot diverge in state-machine semantics.
//
// HIPAA notes:
//   - final_content is PHI: it is accepted as a parameter but never logged or
//     placed in audit metadata. It is only written to the DB as part of the
//     atomic state+audit transaction.
//   - Audit metadata carries only identifiers and action/state strings — no PHI.
package review

import (
	"context"
	"encoding/json"
	"errors"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ErrActorNotFound is returned by Execute when the physician record cannot be
// resolved for the session actor. This is distinct from store.ErrNotFound
// (recommendation not found / no care relationship) so transports can map each
// case to the correct HTTP status: recommendation-not-found → 404,
// physician-not-found → 403 (session/auth anomaly, not a lookup miss).
var ErrActorNotFound = errors.New("review: actor (physician) not found")

// Store is the minimum set of store operations that Execute requires.
// *store.Store satisfies this interface in production; test fakes supply their
// own implementation so tests can run without a real database connection.
type Store interface {
	// GetRecommendationForPhysician returns the recommendation only when the
	// physician has an active care relationship with the patient in the tenant,
	// enforcing access isolation identical to the list path.
	GetRecommendationForPhysician(ctx context.Context, tenant store.TenantID, physicianID, recID uuid.UUID) (store.Recommendation, error)

	// GetPhysician returns the physician record (needed for StatesLicensed).
	GetPhysician(ctx context.Context, tenant store.TenantID, id uuid.UUID) (store.Physician, error)

	// GetPatient returns the patient record (needed for State).
	GetPatient(ctx context.Context, tenant store.TenantID, id uuid.UUID) (store.Patient, error)

	// CreateAuditEvent writes an audit event outside a transaction (used for
	// the unlicensed-state rejection, which has no associated state mutation).
	CreateAuditEvent(ctx context.Context, tenant store.TenantID, e store.AuditEvent) (store.AuditEvent, error)

	// TxnW executes fn atomically inside a transaction. fn receives a
	// store.TxWriter so that *store.TxStore (production) and test fakes can
	// both satisfy the interface without a real database connection.
	TxnW(ctx context.Context, fn func(store.TxWriter) error) error
}

// Result holds the outcome of a successful Execute call.
type Result struct {
	FinalState       string
	PatientID        uuid.UUID
	ConversationID   uuid.UUID
	RecommendationID uuid.UUID
}

// Execute performs the physician review of a recommendation.
//
// Parameters:
//   - tenant, physicianID: from the verified session — never from user input.
//   - recID: the recommendation being reviewed (access-controlled by the store).
//   - action: domain.ActionApprove | domain.ActionModify | domain.ActionReject.
//   - finalContent: the physician's edited text; required for modify, used as
//     override for approve; ignored for reject. PHI — never logged.
//
// Transitions mirror the Core API exactly:
//   - approve:  PENDING_REVIEW → APPROVED → DELIVERED  (final_content set on DELIVERED)
//   - modify:   PENDING_REVIEW → MODIFIED → DELIVERED  (final_content = finalContent, set on DELIVERED)
//   - reject:   PENDING_REVIEW → REJECTED               (final_content stays nil)
//
// Invariants preserved:
//   - DELIVERED is only reachable from APPROVED or MODIFIED.
//   - final_content is set ONLY on the DELIVERED write, never on intermediate states.
//   - State change + audit are written in one DB transaction (atomic).
//   - An unlicensed-state rejection emits an audit event without mutating state;
//     the caller receives domain.ErrUnlicensedState.
//   - A non-care-relationship access returns store.ErrNotFound (no information disclosure).
//   - On delivery (approve/modify reaching DELIVERED), the conversation's care
//     phase moves AWAITING_REVIEW → PLAN_DELIVERED in the same transaction as
//     the state write. If the conversation is not observed in AWAITING_REVIEW
//     (a phase-tracking mismatch), the move is skipped and audited rather than
//     failing the delivery — see the CAS-miss comment at the call site.
//     REJECTED never touches care_phase.
func Execute(
	ctx context.Context,
	s Store,
	tenant store.TenantID,
	physicianID uuid.UUID,
	recID uuid.UUID,
	action string,
	finalContent string,
) (Result, error) {
	// Resolve the recommendation through the care-relationship-scoped query.
	// A physician who is not in an active care relationship with the patient —
	// or whose recommendation belongs to another tenant — receives ErrNotFound
	// (same as "does not exist" to avoid information disclosure).
	rec, err := s.GetRecommendationForPhysician(ctx, tenant, physicianID, recID)
	if err != nil {
		return Result{}, err // ErrNotFound or internal
	}

	// Load the physician's licence list.
	phys, err := s.GetPhysician(ctx, tenant, physicianID)
	if errors.Is(err, store.ErrNotFound) {
		// Should never happen if the JWT actor was validated, but guard anyway.
		// Return ErrActorNotFound (distinct from store.ErrNotFound) so transports
		// can map physician-not-found to 403 rather than 404 — a missing actor
		// is a session/auth anomaly, not a normal lookup miss.
		return Result{}, ErrActorNotFound
	} else if err != nil {
		return Result{}, err
	}

	// Load the patient's state for the licensing check.
	patient, err := s.GetPatient(ctx, tenant, rec.PatientID)
	if errors.Is(err, store.ErrNotFound) {
		return Result{}, store.ErrNotFound
	} else if err != nil {
		return Result{}, err
	}

	actor := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             physicianID,
		StatesLicensed: phys.StatesLicensed,
	}

	// Step 1: validate the physician's action using the canonical pure state
	// machine — moves PENDING_REVIEW → APPROVED / MODIFIED / REJECTED.
	// Transition also enforces the state-licensing invariant.
	midState, err := domain.Transition(rec.State, action, actor, patient.State)
	if errors.Is(err, domain.ErrUnlicensedState) {
		// Write the rejection audit event without touching recommendation state.
		// This is intentionally a standalone (non-TxnW) audit write — there is no
		// state mutation to pair it with, so it does not need to be atomic.
		// Errors from the audit write are suppressed (audit must never block the
		// clinical flow, even when the outcome is a rejection).
		_, _ = s.CreateAuditEvent(ctx, tenant, store.AuditEvent{
			ActorType: "physician",
			ActorID:   &physicianID,
			EventType: "recommendation.review_rejected",
			Metadata: marshalJSON(map[string]any{
				"recommendation_id": recID.String(),
				"action":            action,
				"reason":            "unlicensed_state",
			}),
		})
		return Result{}, domain.ErrUnlicensedState
	}
	if err != nil {
		// ErrInvalidTransition or unexpected error.
		return Result{}, err
	}

	// Step 2: for approve/modify, continue to DELIVERED in the same atomic commit.
	// final_content is set ONLY on the DELIVERED write.
	finalState := midState
	var storedContent *string
	if midState == domain.StateApproved || midState == domain.StateModified {
		delivered, err := domain.Transition(midState, domain.ActionDeliver, actor, patient.State)
		if err != nil {
			// Cannot happen given valid midState values above.
			return Result{}, err
		}
		finalState = delivered

		// Determine the patient-visible content: physician override takes
		// precedence over the agent's draft. PHI — not logged.
		content := rec.DraftContent
		if finalContent != "" {
			content = finalContent
		}
		storedContent = &content
	}
	// For REJECTED: storedContent remains nil — patients never see it.

	// State change AND audit_event written in a single DB transaction so they
	// either both commit or both roll back.
	if err := s.TxnW(ctx, func(tx store.TxWriter) error {
		if err := tx.UpdateRecommendationState(ctx, tenant, recID,
			finalState, &physicianID, storedContent); err != nil {
			return err
		}
		if err := tx.CreateAuditEvent(ctx, tenant, store.AuditEvent{
			ActorType: "physician",
			ActorID:   &physicianID,
			EventType: "recommendation.reviewed",
			Metadata: marshalJSON(map[string]any{
				"recommendation_id": recID.String(),
				"action":            action,
				"new_state":         finalState,
			}),
		}); err != nil {
			return err
		}

		// Step 3: for a delivery (approve/modify reaching DELIVERED), move the
		// conversation AWAITING_REVIEW → PLAN_DELIVERED in the same transaction
		// as the state write above, per design.md ("Phase transitions happen in
		// the same transaction as the event that causes them"). REJECTED never
		// reaches this branch — care_phase is untouched on rejection (Phase 3
		// owns AWAITING_REVIEW → INTAKE for that case).
		if finalState != domain.StateDelivered {
			return nil
		}
		err := tx.TransitionCarePhase(ctx, tenant, rec.ConversationID,
			store.CarePhaseAwaitingReview, store.CarePhasePlanDelivered)
		if err == nil {
			return nil
		}
		if !errors.Is(err, store.ErrNotFound) {
			// Anything other than the CAS miss (e.g. a real DB error) fails the
			// transaction — a delivery must not silently skip its phase move for
			// an unexpected reason.
			return err
		}
		// CAS miss: the conversation was not observed in AWAITING_REVIEW (e.g. a
		// pre-migration/backfilled row, or a state that drifted for some other
		// reason). Deliberately tolerated rather than failed: the care-phase
		// state machine is agent-behaviour routing, not a gate on the
		// physician's clinical decision, and a physician-approved recommendation
		// must never be blocked from reaching the patient over an internal
		// bookkeeping mismatch. Record the mismatch in the audit trail (no PHI)
		// so it is visible for follow-up, and let the delivery commit.
		return tx.CreateAuditEvent(ctx, tenant, store.AuditEvent{
			ActorType: "physician",
			ActorID:   &physicianID,
			EventType: "recommendation.delivered_phase_mismatch",
			Metadata: marshalJSON(map[string]any{
				"recommendation_id": recID.String(),
				"conversation_id":   rec.ConversationID.String(),
			}),
		})
	}); err != nil {
		return Result{}, err
	}

	return Result{
		FinalState:       finalState,
		PatientID:        rec.PatientID,
		ConversationID:   rec.ConversationID,
		RecommendationID: recID,
	}, nil
}

func marshalJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}
