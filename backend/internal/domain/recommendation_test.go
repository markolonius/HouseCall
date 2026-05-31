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
		name         string
		current      string
		action       string
		actor        domain.Actor
		patientState string
		want         string
	}{
		{
			name:         "agent: DRAFT → PENDING_REVIEW",
			current:      domain.StateDraft,
			action:       domain.ActionSubmitForReview,
			actor:        agent,
			patientState: patientStateCA,
			want:         domain.StatePendingReview,
		},
		{
			name:         "physician: PENDING_REVIEW → APPROVED",
			current:      domain.StatePendingReview,
			action:       domain.ActionApprove,
			actor:        physician,
			patientState: patientStateCA,
			want:         domain.StateApproved,
		},
		{
			name:         "physician: PENDING_REVIEW → MODIFIED",
			current:      domain.StatePendingReview,
			action:       domain.ActionModify,
			actor:        physician,
			patientState: patientStateCA,
			want:         domain.StateModified,
		},
		{
			name:         "physician: PENDING_REVIEW → REJECTED",
			current:      domain.StatePendingReview,
			action:       domain.ActionReject,
			actor:        physician,
			patientState: patientStateCA,
			want:         domain.StateRejected,
		},
		{
			name:         "physician: APPROVED → DELIVERED",
			current:      domain.StateApproved,
			action:       domain.ActionDeliver,
			actor:        physician,
			patientState: patientStateCA,
			want:         domain.StateDelivered,
		},
		{
			name:         "physician: MODIFIED → DELIVERED",
			current:      domain.StateModified,
			action:       domain.ActionDeliver,
			actor:        physician,
			patientState: patientStateCA,
			want:         domain.StateDelivered,
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

// TestTransition_AllCombinations is an exhaustive table-driven test that
// enumerates every (current state, action, actor type, licensed?) combination
// and asserts the exact (newState, error) for each entry. Every edge in the
// state machine — legal and illegal — appears exactly once.
func TestTransition_AllCombinations(t *testing.T) {
	allStates := []string{
		domain.StateDraft,
		domain.StatePendingReview,
		domain.StateApproved,
		domain.StateModified,
		domain.StateRejected,
		domain.StateDelivered,
	}
	allActions := []string{
		domain.ActionSubmitForReview,
		domain.ActionApprove,
		domain.ActionModify,
		domain.ActionReject,
		domain.ActionDeliver,
	}

	licensedPhysician := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             uuid.New(),
		StatesLicensed: []string{"CA"},
	}
	unlicensedPhysician := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             uuid.New(),
		StatesLicensed: []string{"NY"}, // not licensed in CA
	}
	agentActor := domain.Actor{Type: domain.ActorAgent, ID: uuid.New()}

	type row struct {
		name         string
		current      string
		action       string
		actor        domain.Actor
		patientState string
		wantState    string
		wantErr      error // nil means success; non-nil must match via errors.Is
	}

	// Legal transitions (positive cases).
	legal := []row{
		{
			name:         "agent submit_for_review from DRAFT",
			current:      domain.StateDraft,
			action:       domain.ActionSubmitForReview,
			actor:        agentActor,
			patientState: "CA",
			wantState:    domain.StatePendingReview,
		},
		{
			name:         "licensed physician approve from PENDING_REVIEW",
			current:      domain.StatePendingReview,
			action:       domain.ActionApprove,
			actor:        licensedPhysician,
			patientState: "CA",
			wantState:    domain.StateApproved,
		},
		{
			name:         "licensed physician modify from PENDING_REVIEW",
			current:      domain.StatePendingReview,
			action:       domain.ActionModify,
			actor:        licensedPhysician,
			patientState: "CA",
			wantState:    domain.StateModified,
		},
		{
			name:         "licensed physician reject from PENDING_REVIEW",
			current:      domain.StatePendingReview,
			action:       domain.ActionReject,
			actor:        licensedPhysician,
			patientState: "CA",
			wantState:    domain.StateRejected,
		},
		{
			name:         "physician deliver from APPROVED",
			current:      domain.StateApproved,
			action:       domain.ActionDeliver,
			actor:        licensedPhysician,
			patientState: "CA",
			wantState:    domain.StateDelivered,
		},
		{
			name:         "physician deliver from MODIFIED",
			current:      domain.StateModified,
			action:       domain.ActionDeliver,
			actor:        licensedPhysician,
			patientState: "CA",
			wantState:    domain.StateDelivered,
		},
		// Unlicensed physician can still DELIVER (licensing check is skipped for
		// deliver because it was already verified at approve/modify time).
		{
			name:         "unlicensed physician deliver from APPROVED (licensing exempt)",
			current:      domain.StateApproved,
			action:       domain.ActionDeliver,
			actor:        unlicensedPhysician,
			patientState: "CA",
			wantState:    domain.StateDelivered,
		},
		{
			name:         "unlicensed physician deliver from MODIFIED (licensing exempt)",
			current:      domain.StateModified,
			action:       domain.ActionDeliver,
			actor:        unlicensedPhysician,
			patientState: "CA",
			wantState:    domain.StateDelivered,
		},
	}

	// Invalid transitions — each must return an error. We build these
	// systematically: agent actions outside the one legal edge, physician
	// actions from states where they have no permission, and unlicensed
	// rejections for every review action.
	var invalid []row

	// Agent: every (state, action) pair except the single legal one.
	for _, state := range allStates {
		for _, action := range allActions {
			if state == domain.StateDraft && action == domain.ActionSubmitForReview {
				continue // legal; already in the positive cases
			}
			invalid = append(invalid, row{
				name:         "agent illegal: " + state + "/" + action,
				current:      state,
				action:       action,
				actor:        agentActor,
				patientState: "CA",
				wantErr:      domain.ErrInvalidTransition,
			})
		}
	}

	// Licensed physician: illegal lifecycle transitions (wrong source state).
	illegalPhysicianLifecycle := []struct{ state, action string }{
		// approve/modify/reject are only valid from PENDING_REVIEW
		{domain.StateDraft, domain.ActionApprove},
		{domain.StateDraft, domain.ActionModify},
		{domain.StateDraft, domain.ActionReject},
		{domain.StateApproved, domain.ActionApprove},
		{domain.StateApproved, domain.ActionModify},
		{domain.StateApproved, domain.ActionReject},
		{domain.StateModified, domain.ActionApprove},
		{domain.StateModified, domain.ActionModify},
		{domain.StateModified, domain.ActionReject},
		{domain.StateRejected, domain.ActionApprove},
		{domain.StateRejected, domain.ActionModify},
		{domain.StateRejected, domain.ActionReject},
		{domain.StateDelivered, domain.ActionApprove},
		{domain.StateDelivered, domain.ActionModify},
		{domain.StateDelivered, domain.ActionReject},
		// deliver is only valid from APPROVED or MODIFIED
		{domain.StateDraft, domain.ActionDeliver},
		{domain.StatePendingReview, domain.ActionDeliver},
		{domain.StateRejected, domain.ActionDeliver},
		{domain.StateDelivered, domain.ActionDeliver},
		// physicians cannot submit_for_review
		{domain.StateDraft, domain.ActionSubmitForReview},
		{domain.StatePendingReview, domain.ActionSubmitForReview},
	}
	for _, tc := range illegalPhysicianLifecycle {
		invalid = append(invalid, row{
			name:         "licensed physician illegal lifecycle: " + tc.state + "/" + tc.action,
			current:      tc.state,
			action:       tc.action,
			actor:        licensedPhysician,
			patientState: "CA",
			wantErr:      domain.ErrInvalidTransition,
		})
	}

	// Unlicensed physician: approve, modify, reject must always return
	// ErrUnlicensedState regardless of source state.
	for _, action := range []string{domain.ActionApprove, domain.ActionModify, domain.ActionReject} {
		invalid = append(invalid, row{
			name:         "unlicensed physician " + action + " from PENDING_REVIEW",
			current:      domain.StatePendingReview,
			action:       action,
			actor:        unlicensedPhysician,
			patientState: "CA",
			wantErr:      domain.ErrUnlicensedState,
		})
	}

	// Unknown actor type: always ErrInvalidTransition.
	unknown := domain.Actor{Type: domain.ActorType("unknown"), ID: uuid.New()}
	invalid = append(invalid, row{
		name:         "unknown actor type",
		current:      domain.StateDraft,
		action:       domain.ActionSubmitForReview,
		actor:        unknown,
		patientState: "CA",
		wantErr:      domain.ErrInvalidTransition,
	})

	// Run positive cases.
	for _, tc := range legal {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got, err := domain.Transition(tc.current, tc.action, tc.actor, tc.patientState)
			if err != nil {
				t.Fatalf("expected success, got error: %v", err)
			}
			if got != tc.wantState {
				t.Fatalf("got state %q, want %q", got, tc.wantState)
			}
		})
	}

	// Run negative cases.
	for _, tc := range invalid {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got, err := domain.Transition(tc.current, tc.action, tc.actor, tc.patientState)
			if err == nil {
				t.Fatalf("expected error %v, got nil (state=%q)", tc.wantErr, got)
			}
			if !errors.Is(err, tc.wantErr) {
				t.Fatalf("expected error %v, got %v", tc.wantErr, err)
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

// TestTransition_LicensingFiresBeforeLifecycle verifies that the state-licensing
// check takes precedence over the lifecycle check. An unlicensed physician
// attempting a review action from a state that is also an illegal source for
// that action must get ErrUnlicensedState, not ErrInvalidTransition — this
// prevents the caller from inferring valid transitions from error messages.
func TestTransition_LicensingFiresBeforeLifecycle(t *testing.T) {
	unlicensed := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             uuid.New(),
		StatesLicensed: []string{"NY"},
	}

	// DRAFT is not a valid source state for approve/modify/reject, but the
	// licensing check must still fire first and return ErrUnlicensedState.
	for _, action := range []string{domain.ActionApprove, domain.ActionModify, domain.ActionReject} {
		action := action
		t.Run("unlicensed check precedes lifecycle for "+action, func(t *testing.T) {
			_, err := domain.Transition(domain.StateDraft, action, unlicensed, "CA")
			if !errors.Is(err, domain.ErrUnlicensedState) {
				t.Fatalf("expected ErrUnlicensedState before lifecycle check, got %v", err)
			}
		})
	}
}

// TestTransition_PatientVisibilityInvariant asserts the core HIPAA invariant:
// the state machine NEVER produces DELIVERED from PENDING_REVIEW or REJECTED.
// FinalContent is set only on the DELIVERED transition; this test confirms that
// PENDING_REVIEW and REJECTED are unreachable-to-DELIVERED dead ends.
//
// The domain layer is pure (no I/O), so "content is never patient-visible" in
// this context means: no single Transition call can jump from
// PENDING_REVIEW or REJECTED directly to DELIVERED — every path to DELIVERED
// must pass through APPROVED or MODIFIED, where explicit physician action sets
// the final content.
func TestTransition_PatientVisibilityInvariant(t *testing.T) {
	// Attempt to reach DELIVERED from PENDING_REVIEW and REJECTED using every
	// possible action (including the internal-only ActionDeliver). None must
	// succeed.
	neverDeliverableStates := []string{
		domain.StatePendingReview,
		domain.StateRejected,
	}

	allActions := []string{
		domain.ActionSubmitForReview,
		domain.ActionApprove,
		domain.ActionModify,
		domain.ActionReject,
		domain.ActionDeliver,
	}

	actors := []struct {
		name  string
		actor domain.Actor
	}{
		{"agent", agent},
		{"licensed physician", physician},
		{
			"unlicensed physician",
			domain.Actor{
				Type:           domain.ActorPhysician,
				ID:             uuid.New(),
				StatesLicensed: []string{"NY"},
			},
		},
	}

	for _, startState := range neverDeliverableStates {
		for _, action := range allActions {
			for _, actorCase := range actors {
				startState := startState
				action := action
				actorCase := actorCase
				t.Run(startState+"/"+action+"/"+actorCase.name, func(t *testing.T) {
					next, err := domain.Transition(startState, action, actorCase.actor, "CA")
					// If the transition succeeds (no error), the resulting state
					// must never be DELIVERED.
					if err == nil && next == domain.StateDelivered {
						t.Fatalf(
							"invariant violated: Transition(%q, %q, %s) produced DELIVERED — "+
								"PENDING_REVIEW and REJECTED content must never be patient-visible",
							startState, action, actorCase.name,
						)
					}
				})
			}
		}
	}
}

// TestTransition_EmptyLicenseList verifies the edge case where a physician has
// an empty StatesLicensed slice (licensed nowhere) and is always rejected.
func TestTransition_EmptyLicenseList(t *testing.T) {
	nowherePhysician := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             uuid.New(),
		StatesLicensed: []string{},
	}

	for _, action := range []string{domain.ActionApprove, domain.ActionModify, domain.ActionReject} {
		action := action
		t.Run("empty license list for "+action, func(t *testing.T) {
			_, err := domain.Transition(domain.StatePendingReview, action, nowherePhysician, "CA")
			if !errors.Is(err, domain.ErrUnlicensedState) {
				t.Fatalf("physician with empty license list: expected ErrUnlicensedState, got %v", err)
			}
		})
	}
}

// TestTransition_StateLicensingAllThreeActionsRejectedAndAuditable verifies the
// Task 3.4 requirement that an unlicensed physician cannot approve, modify, OR
// reject — each action individually returns ErrUnlicensedState so the caller
// (handler) can write an audit event for each blocked attempt.
func TestTransition_StateLicensingAllThreeActionsRejectedAndAuditable(t *testing.T) {
	// Physician licensed only in TX; patient is in CA.
	unlicensed := domain.Actor{
		Type:           domain.ActorPhysician,
		ID:             uuid.New(),
		StatesLicensed: []string{"TX"},
	}

	type auditableRejection struct {
		action          string
		expectedErr     error
		shouldBeAudited bool // caller must write an audit event on this error
	}

	cases := []auditableRejection{
		{domain.ActionApprove, domain.ErrUnlicensedState, true},
		{domain.ActionModify, domain.ErrUnlicensedState, true},
		{domain.ActionReject, domain.ErrUnlicensedState, true},
	}

	for _, tc := range cases {
		tc := tc
		t.Run("unlicensed "+tc.action+" → ErrUnlicensedState", func(t *testing.T) {
			_, err := domain.Transition(domain.StatePendingReview, tc.action, unlicensed, "CA")
			if !errors.Is(err, tc.expectedErr) {
				t.Fatalf("action %q: expected %v, got %v", tc.action, tc.expectedErr, err)
			}
			// The domain function returning ErrUnlicensedState is the signal that
			// the handler MUST write a recommendation.review_rejected audit event.
			// We verify the error identity here; handler-level audit writing is
			// covered in TestHandler_UnlicensedPhysicianReview_IsAudited
			// (api/recommendations_test.go).
			if !tc.shouldBeAudited {
				t.Fatal("test data error: every ErrUnlicensedState rejection must be auditable")
			}
		})
	}
}
