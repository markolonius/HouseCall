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

	agent     = domain.Actor{Type: domain.ActorAgent, ID: agentID}
	physician = domain.Actor{Type: domain.ActorPhysician, ID: physicianID}
)

// TestTransition_ValidPaths checks every permitted edge in the state machine.
func TestTransition_ValidPaths(t *testing.T) {
	cases := []struct {
		name    string
		current string
		action  string
		actor   domain.Actor
		want    string
	}{
		{
			name:    "agent: DRAFT → PENDING_REVIEW",
			current: domain.StateDraft,
			action:  domain.ActionSubmitForReview,
			actor:   agent,
			want:    domain.StatePendingReview,
		},
		{
			name:    "physician: PENDING_REVIEW → APPROVED",
			current: domain.StatePendingReview,
			action:  domain.ActionApprove,
			actor:   physician,
			want:    domain.StateApproved,
		},
		{
			name:    "physician: PENDING_REVIEW → MODIFIED",
			current: domain.StatePendingReview,
			action:  domain.ActionModify,
			actor:   physician,
			want:    domain.StateModified,
		},
		{
			name:    "physician: PENDING_REVIEW → REJECTED",
			current: domain.StatePendingReview,
			action:  domain.ActionReject,
			actor:   physician,
			want:    domain.StateRejected,
		},
		{
			name:    "physician: APPROVED → DELIVERED",
			current: domain.StateApproved,
			action:  domain.ActionDeliver,
			actor:   physician,
			want:    domain.StateDelivered,
		},
		{
			name:    "physician: MODIFIED → DELIVERED",
			current: domain.StateModified,
			action:  domain.ActionDeliver,
			actor:   physician,
			want:    domain.StateDelivered,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := domain.Transition(tc.current, tc.action, tc.actor)
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
			_, err := domain.Transition(current, domain.ActionDeliver, physician)
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
	next, err := domain.Transition(domain.StateDraft, domain.ActionSubmitForReview, agent)
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
			_, err := domain.Transition(tc.current, tc.action, agent)
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
	_, err := domain.Transition(domain.StateDraft, domain.ActionSubmitForReview, unknown)
	if !errors.Is(err, domain.ErrInvalidTransition) {
		t.Fatalf("expected ErrInvalidTransition for unknown actor, got %v", err)
	}
}
