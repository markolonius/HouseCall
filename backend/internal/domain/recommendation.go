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

// Physician review actions.
const (
	ActionApprove = "approve"
	ActionModify  = "modify"
	ActionReject  = "reject"
)

var (
	// ErrInvalidTransition is returned when the requested transition is not
	// legal from the current state.
	ErrInvalidTransition = errors.New("domain: invalid state transition")
)

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
// State-licensing enforcement (physician.states_licensed ∋ patient.state)
// is added in Phase 3 (Task 3.3).
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
