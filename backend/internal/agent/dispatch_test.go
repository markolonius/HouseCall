// Package agent — internal tests for care-phase dispatch in DraftAsync
// (Task 2.1).
//
// Uses "package agent" to access the unexported dispatchTurn symbol and to
// reuse setupIntegrationFixture / sequentialClient (interview_flow_integration_test.go,
// carveout_test.go), spyClient (interview_turn_test.go), captureNotifier
// (soap_drafter_test.go), and spyPatientNotifier (deliver_question_test.go)
// — all declared in this same package's other test files.
package agent

import (
	"context"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// noRecommendationForConv is a small assertion helper: fails the test if any
// DRAFT or PENDING_REVIEW recommendation exists for convID. Used to prove the
// AWAITING_REVIEW/PLAN_DELIVERED dispatch branches did not create a second
// recommendation (the double-draft bug this change guards against).
func noRecommendationForConv(t *testing.T, s *store.Store, tenantID store.TenantID, convID uuid.UUID) {
	t.Helper()
	ctx := context.Background()
	for _, state := range []string{domain.StateDraft, domain.StatePendingReview} {
		recs, err := s.ListRecommendationsByState(ctx, tenantID, state)
		if err != nil {
			t.Fatalf("list %s recs: %v", state, err)
		}
		for _, r := range recs {
			if r.ConversationID == convID {
				t.Errorf("unexpected %s recommendation for conversation %s", state, convID)
			}
		}
	}
}

// TestDispatchTurn_AwaitingReview_NoModelCallNoRecommendation proves the
// AWAITING_REVIEW branch of dispatchTurn does not call the model and does not
// create a recommendation, but DOES notify the patient with the fixed
// "report is with your physician" reminder (task 2.3) — the dispatch itself
// is the double-draft guard.
func TestDispatchTurn_AwaitingReview_NoModelCallNoRecommendation(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	conv := f.Conv
	conv.CarePhase = store.CarePhaseAwaitingReview

	spy := &spyClient{text: "MODEL SHOULD NOT BE CALLED"}
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(spy, s, physNotifier, patNotifier)

	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("dispatchTurn: %v", err)
	}

	if len(spy.captured) != 0 {
		t.Errorf("expected 0 model calls for AWAITING_REVIEW, got %d", len(spy.captured))
	}
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 physician notifications for AWAITING_REVIEW, got %d", physNotifier.count())
	}
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification (the reminder) for AWAITING_REVIEW, got %d", patNotifier.count())
	}
	noRecommendationForConv(t, s, f.TenantID, conv.ID)
}

// TestDispatchTurn_PlanDelivered_RunsRelayTurn proves the PLAN_DELIVERED
// branch of dispatchTurn now routes to the post-approval plan relay (task
// 4.2): given a conversation with a delivered recommendation to ground on,
// dispatchTurn makes a model call and persists a relay reply. This
// supersedes the earlier no-op assertion (task 4.1's stub); see
// relay_flow_integration_test.go for the full relay scenario coverage
// (explain, defer, new-complaint, model failure).
func TestDispatchTurn_PlanDelivered_RunsRelayTurn(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupRelayFixture(t, s) // relay_flow_integration_test.go (same package)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "What does the plan say about follow-up?"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const reply = "Your plan says to follow up if symptoms worsen or you develop a fever above 102F."
	spy := &spyClient{text: reply}
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(spy, s, physNotifier, patNotifier)

	if err := d.dispatchTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("dispatchTurn: %v", err)
	}

	if len(spy.captured) != 1 {
		t.Errorf("expected 1 model call for PLAN_DELIVERED relay, got %d", len(spy.captured))
	}
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 physician notifications for a PLAN_DELIVERED relay reply, got %d", physNotifier.count())
	}
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the relay reply, got %d", patNotifier.count())
	}
	noRecommendationForConv(t, s, f.TenantID, f.Conv.ID)
}

// TestDispatchTurn_Intake_RunsInterviewTurn proves the INTAKE branch still
// runs the ordinary interview turn (the regression guard task 2.1 asks for).
// Since task 5.2, INTAKE dispatch runs a triage classification call before
// the interview turn (see runIntakeTurn), so this uses a sequentialClient
// scripted with a routine triage result followed by the interview question,
// and asserts both calls happened.
func TestDispatchTurn_Intake_RunsInterviewTurn(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	conv := f.Conv
	conv.CarePhase = store.CarePhaseIntake

	const question = "How long have you had this headache?"
	client := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: RoutineMarker},
		{text: question},
	}}
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("dispatchTurn: %v", err)
	}

	if client.idx != 2 {
		t.Fatalf("expected 2 model calls for INTAKE (triage + interview), got %d", client.idx)
	}
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the interview question, got %d", patNotifier.count())
	}
}

// TestDispatchTurn_EmptyCarePhase_TreatedAsIntake proves the defensive
// fallback: a Conversation with a zero-value CarePhase (pre-migration rows or
// older in-memory fixtures) is dispatched as INTAKE rather than silently
// dropped. Like TestDispatchTurn_Intake_RunsInterviewTurn, this now scripts a
// routine triage result ahead of the interview question (task 5.2).
func TestDispatchTurn_EmptyCarePhase_TreatedAsIntake(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	conv := f.Conv
	conv.CarePhase = "" // zero value, not a real phase

	const question = "Any fever or chills?"
	client := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: RoutineMarker},
		{text: question},
	}}
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("dispatchTurn: %v", err)
	}

	if client.idx != 2 {
		t.Fatalf("expected empty CarePhase to fall back to INTAKE (2 model calls: triage + interview), got %d", client.idx)
	}
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the fallback interview turn, got %d", patNotifier.count())
	}
}

// TestDraftAsync_AwaitingReview_NoModelCall exercises the production entry
// point (DraftAsync, not dispatchTurn directly) end-to-end for the
// AWAITING_REVIEW phase, proving the goroutine wiring dispatches correctly.
func TestDraftAsync_AwaitingReview_NoModelCall(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)

	conv := f.Conv
	conv.CarePhase = store.CarePhaseAwaitingReview

	spy := &spyClient{text: "MODEL SHOULD NOT BE CALLED"}
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}

	var wg sync.WaitGroup
	wg.Add(1)
	d := NewDrafter(spy, s, physNotifier, patNotifier).WithOnComplete(wg.Done)

	d.DraftAsync(f.TenantID, conv, f.Patient)
	wg.Wait()

	if len(spy.captured) != 0 {
		t.Errorf("expected 0 model calls via DraftAsync for AWAITING_REVIEW, got %d", len(spy.captured))
	}
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification (the reminder) via DraftAsync for AWAITING_REVIEW, got %d", patNotifier.count())
	}
	noRecommendationForConv(t, s, f.TenantID, conv.ID)
}
