package domain_test

import (
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/markolonius/housecall/backend/internal/domain"
)

var (
	agentID     = uuid.New()
	physicianID = uuid.New()

	agent = domain.Actor{Type: domain.ActorAgent, ID: agentID}
	// physician is licensed in "CA" — used with patientStateCA in tests that
	// exercise the happy path (licensed physician acts on a CA patient).
	physician = domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             physicianID,
		StatesLicensed: []string{"CA"},
	}
	patientStateCA = "CA"
)

// TestTransition_ValidPaths checks every permitted edge in the state machine.
func TestTransition_ValidPaths(t *testing.T) {
	cases := []struct {
		name        string
		current     string
		action      string
		actor       domain.Actor
		patientState string
		want        string
	}{
		{
			name:        "agent: DRAFT → PENDING_REVIEW",
			current:     domain.StateDraft,
			action:      domain.ActionSubmitForReview,
			actor:       agent,
			patientState: patientStateCA,
			want:        domain.StatePendingReview,
		},
		{
			name:        "physician: PENDING_REVIEW → APPROVED",
			current:     domain.StatePendingReview,
			action:      domain.ActionApprove,
			actor:       physician,
			patientState: patientStateCA,
			want:        domain.StateApproved,
		},
		{
			name:        "physician: PENDING_REVIEW → MODIFIED",
			current:     domain.StatePendingReview,
			action:      domain.ActionModify,
			actor:       physician,
			patientState: patientStateCA,
			want:        domain.StateModified,
		},
		{
			name:        "physician: PENDING_REVIEW → REJECTED",
			current:     domain.StatePendingReview,
			action:      domain.ActionReject,
			actor:       physician,
			patientState: patientStateCA,
			want:        domain.StateRejected,
		},
		{
			name:        "physician: APPROVED → DELIVERED",
			current:     domain.StateApproved,
			action:      domain.ActionDeliver,
			actor:       physician,
			patientState: patientStateCA,
			want:        domain.StateDelivered,
		},
		{
			name:        "physician: MODIFIED → DELIVERED",
			current:     domain.StateModified,
			action:      domain.ActionDeliver,
			actor:       physician,
			patientState: patientStateCA,
			want:        domain.StateDelivered,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := domain.Transition(tc.current, tc.action, tc.actor, tc.patientState)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got state %q, want %q", got, tc.want)
			}
		})
	}
}

// TestTransition_DeliveredOnlyFromApprovedOrModified asserts the invariant that
// DELIVERED is unreachable from any state other than APPROVED or MODIFIED.
func TestTransition_DeliveredOnlyFromApprovedOrModified(t *testing.T) {
	forbidden := []string{
		domain.StateDraft,
		domain.StatePendingReview,
		domain.StateRejected,
		domain.StateDelivered,
	}

	for _, current := range forbidden {
		t.Run("deliver from "+current, func(t *testing.T) {
			_, err := domain.Transition(current, domain.ActionDeliver, physician, patientStateCA)
			if !errors.Is(err, domain.ErrInvalidTransition) {
				t.Fatalf("expected ErrInvalidTransition, got %v", err)
			}
		})
	}
}

// TestTransition_AgentBoundary asserts the agent can only move DRAFT →
// PENDING_REVIEW and has no other code path.
func TestTransition_AgentBoundary(t *testing.T) {
	// The only permitted agent action.
	next, err := domain.Transition(domain.StateDraft, domain.ActionSubmitForReview, agent, patientStateCA)
	if err != nil {
		t.Fatalf("agent submit_for_review from DRAFT: unexpected error: %v", err)
	}
	if next != domain.StatePendingReview {
		t.Fatalf("expected PENDING_REVIEW, got %q", next)
	}

	// Agent must not reach any physician-gated state.
	agentForbidden := []struct {
		current string
		action  string
	}{
		{domain.StatePendingReview, domain.ActionApprove},
		{domain.StatePendingReview, domain.ActionModify},
		{domain.StatePendingReview, domain.ActionReject},
		{domain.StateApproved, domain.ActionDeliver},
		{domain.StateModified, domain.ActionDeliver},
		// Agent cannot even re-submit its own already-submitted draft.
		{domain.StatePendingReview, domain.ActionSubmitForReview},
	}

	for _, tc := range agentForbidden {
		t.Run("agent blocked: "+tc.current+"/"+tc.action, func(t *testing.T) {
			_, err := domain.Transition(tc.current, tc.action, agent, patientStateCA)
			if !errors.Is(err, domain.ErrInvalidTransition) {
				t.Fatalf("expected ErrInvalidTransition, got %v", err)
			}
		})
	}
}

// TestTransition_UnknownActor verifies that an unrecognised actor type is always
// rejected rather than silently permitted.
func TestTransition_UnknownActor(t *testing.T) {
	unknown := domain.Actor{Type: domain.ActorType("unknown"), ID: uuid.New()}
	_, err := domain.Transition(domain.StateDraft, domain.ActionSubmitForReview, unknown, patientStateCA)
	if !errors.Is(err, domain.ErrInvalidTransition) {
		t.Fatalf("expected ErrInvalidTransition for unknown actor, got %v", err)
	}
}

// TestTransition_StateLicensing checks that an unlicensed physician is rejected
// with ErrUnlicensedState for all three review actions, and that a licensed
// physician in the same state passes the check.
func TestTransition_StateLicensing(t *testing.T) {
	unlicensed := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             uuid.New(),
		StatesLicensed: []string{"NY", "TX"}, // not licensed in CA
	}
	licensed := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             uuid.New(),
		StatesLicensed: []string{"CA", "NY"},
	}

	reviewActions := []string{
		domain.ActionApprove,
		domain.ActionModify,
		domain.ActionReject,
	}

	for _, action := range reviewActions {
		action := action
		t.Run("unlicensed physician rejected for "+action, func(t *testing.T) {
			_, err := domain.Transition(domain.StatePendingReview, action, unlicensed, "CA")
			if !errors.Is(err, domain.ErrUnlicensedState) {
				t.Fatalf("expected ErrUnlicensedState, got %v", err)
			}
		})

		t.Run("licensed physician allowed for "+action, func(t *testing.T) {
			_, err := domain.Transition(domain.StatePendingReview, action, licensed, "CA")
			if err != nil {
				// ErrUnlicensedState must not be returned; other errors (e.g.
				// ErrInvalidTransition for ActionModify when no content provided)
				// are acceptable since we are only testing the licensing gate here.
				if errors.Is(err, domain.ErrUnlicensedState) {
					t.Fatalf("licensed physician got ErrUnlicensedState: %v", err)
				}
			}
		})
	}

	// ActionDeliver is exempt from the licensing check; an unlicensed physician
	// must not receive ErrUnlicensedState for that internal-only action (it will
	// get ErrInvalidTransition from the lifecycle check instead if needed).
	t.Run("deliver action not subject to licensing check", func(t *testing.T) {
		// From APPROVED the deliver is a valid lifecycle step regardless of licensing.
		_, err := domain.Transition(domain.StateApproved, domain.ActionDeliver, unlicensed, "CA")
		if errors.Is(err, domain.ErrUnlicensedState) {
			t.Fatalf("ActionDeliver must not be gated by licensing, got ErrUnlicensedState")
		}
	})
}
