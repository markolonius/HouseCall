// Package domain holds the Recommendation state machine. It is pure (no I/O)
// so it can be tested exhaustively without a database.
package domain

import (
	"errors"

	"github.com/google/uuid"
)

// Recommendation states.
const (
	StateDraft         = "DRAFT"
	StatePendingReview = "PENDING_REVIEW"
	StateApproved      = "APPROVED"
	StateModified      = "MODIFIED"
	StateRejected      = "REJECTED"
	StateDelivered     = "DELIVERED"
)

// Actor types identify who is performing a state-machine transition.
type ActorType string

const (
	ActorAgent     ActorType = "agent"
	ActorPhysician ActorType = "physician"
)

// Actor carries the type, identity, and licensing information of the entity
// requesting a transition.
type Actor struct {
	Type           ActorType
	ID             uuid.UUID
	// StatesLicensed is the set of USPS state codes in which this physician
	// holds an active licence. Required for ActorPhysician; ignored for
	// ActorAgent. An empty slice means the physician is licensed nowhere.
	StatesLicensed []string
}

// Actions that any actor may request.
const (
	// Agent actions — the agent may ONLY use this action.
	ActionSubmitForReview = "submit_for_review"

	// Physician review actions.
	ActionApprove = "approve"
	ActionModify  = "modify"
	ActionReject  = "reject"

	// Internal: transition an already-reviewed recommendation to DELIVERED.
	// Only reachable from APPROVED or MODIFIED; not exposed to external callers
	// directly — it is triggered by the review flow.
	ActionDeliver = "deliver"
)

var (
	// ErrInvalidTransition is returned when the requested transition is not
	// legal from the current state, or when the actor does not have permission
	// to perform the action.
	ErrInvalidTransition = errors.New("domain: invalid state transition")

	// ErrUnlicensedState is returned by Transition when a physician actor
	// attempts to approve, modify, or reject a recommendation whose patient
	// resides in a state for which the physician holds no active licence.
	// The recommendation state is NOT changed when this error is returned.
	ErrUnlicensedState = errors.New("domain: physician not licensed in patient's state")
)

// Transition is the canonical pure state-machine function. It returns the next
// state for a given (current, action, actor, patientState) tuple, or an error
// if the combination is illegal.
//
// Permitted transitions:
//
//	Agent   submit_for_review : DRAFT          → PENDING_REVIEW
//	Physician approve          : PENDING_REVIEW → APPROVED
//	Physician modify           : PENDING_REVIEW → MODIFIED
//	Physician reject           : PENDING_REVIEW → REJECTED
//	Physician deliver          : APPROVED       → DELIVERED
//	Physician deliver          : MODIFIED       → DELIVERED
//
// Invariants enforced:
//   - DELIVERED is reachable ONLY from APPROVED or MODIFIED.
//   - The agent actor has no code path beyond DRAFT → PENDING_REVIEW.
//   - A physician actor whose StatesLicensed does not include patientState is
//     rejected with ErrUnlicensedState for approve, modify, and reject actions.
//     The state-licensing check fires before the lifecycle check so that an
//     unlicensed physician cannot infer valid transitions from error messages.
//     patientState is ignored for ActionDeliver (an internal-only step) and for
//     ActorAgent (agents are not subject to licensing).
func Transition(current, action string, actor Actor, patientState string) (string, error) {
	switch actor.Type {
	case ActorAgent:
		// The agent is permitted exactly one transition.
		if current == StateDraft && action == ActionSubmitForReview {
			return StatePendingReview, nil
		}
		return "", ErrInvalidTransition

	case ActorPhysician:
		// State-licensing check: applies to the three review actions.
		// ActionDeliver is an internal step triggered only after a successful
		// approve/modify, so licensing has already been verified.
		if action == ActionApprove || action == ActionModify || action == ActionReject {
			if !isLicensedIn(actor.StatesLicensed, patientState) {
				return "", ErrUnlicensedState
			}
		}

		switch {
		case current == StatePendingReview && action == ActionApprove:
			return StateApproved, nil
		case current == StatePendingReview && action == ActionModify:
			return StateModified, nil
		case current == StatePendingReview && action == ActionReject:
			return StateRejected, nil
		// DELIVERED is reachable ONLY from APPROVED or MODIFIED.
		case (current == StateApproved || current == StateModified) && action == ActionDeliver:
			return StateDelivered, nil
		default:
			return "", ErrInvalidTransition
		}

	default:
		return "", ErrInvalidTransition
	}
}

// isLicensedIn reports whether licences contains state (case-sensitive USPS
// code comparison). Returns false when licences is empty or state is empty.
func isLicensedIn(licences []string, state string) bool {
	if state == "" {
		return false
	}
	for _, s := range licences {
		if s == state {
			return true
		}
	}
	return false
}

// ReviewResult is the computed outcome of a physician review action.
type ReviewResult struct {
	State        string
	FinalContent *string  // nil for REJECTED; set for DELIVERED
	ReviewedBy   uuid.UUID
}

// TransitionReview validates and computes the outcome of a physician review
// action on a recommendation that is currently in StatePendingReview.
//
//   approve → DELIVERED  (final_content = draftContent unless finalContent provided)
//   modify  → DELIVERED  (finalContent must be non-empty)
//   reject  → REJECTED   (final_content not set)
//
// Deprecated: TransitionReview predates the two-step Transition flow introduced
// in Task 3.1/3.2 and does not enforce state-licensing (Task 3.3). Use
// Transition with ActorPhysician instead. This function is retained to avoid
// breaking callers but must not be used in new code — it bypasses the
// licensing invariant.
func TransitionReview(current, action string, physicianID uuid.UUID, draftContent, finalContent string) (ReviewResult, error) {
	if current != StatePendingReview {
		return ReviewResult{}, ErrInvalidTransition
	}
	switch action {
	case ActionApprove:
		fc := draftContent
		if finalContent != "" {
			fc = finalContent
		}
		return ReviewResult{State: StateDelivered, FinalContent: &fc, ReviewedBy: physicianID}, nil
	case ActionModify:
		if finalContent == "" {
			return ReviewResult{}, errors.New("domain: final_content required for modify")
		}
		return ReviewResult{State: StateDelivered, FinalContent: &finalContent, ReviewedBy: physicianID}, nil
	case ActionReject:
		return ReviewResult{State: StateRejected, ReviewedBy: physicianID}, nil
	default:
		return ReviewResult{}, ErrInvalidTransition
	}
}
