// Package agent — regression test for the 2026-07-15 double-draft production
// bug (bead HouseCall-lkzs), fixed by task 2.3's runAwaitingReviewTurn.
//
// Uses "package agent" to access DraftAsync/dispatchTurn end-to-end and to
// reuse setupIntegrationFixture, sequentialClient, wellFormedSOAPText,
// spyPhysicianNotifier (carveout_test.go / interview_flow_integration_test.go
// / soap_drafter_test.go), and spyPatientNotifier (deliver_question_test.go)
// — all declared in this same package's other test files.
package agent

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// TestDoubleDraftBug_AwaitingReview_SecondMessageDoesNotRedraft reproduces the
// 2026-07-15 double-draft bug end-to-end and proves task 2.3 fixes it:
//
//  1. A conversation in INTAKE completes its interview (the model emits
//     ReadyForNoteMarker) → the drafter persists a soap_note recommendation at
//     PENDING_REVIEW, the fixed review-pending ack, and moves the conversation
//     to AWAITING_REVIEW (task 2.2), all via the production DraftAsync entry
//     point.
//  2. The patient sends ANOTHER message while the draft is still awaiting
//     physician review — exactly the scenario that used to silently produce a
//     second soap_note draft before care-phase dispatch existed.
//  3. DraftAsync runs again, this time observing the conversation's
//     AWAITING_REVIEW phase.
//
// Assertions prove the bug is fixed: exactly ONE recommendation exists for the
// conversation after the second message (no second draft), the fixed
// "report is with your physician" reminder was persisted (distinct wording
// from the task-2.2 ack) and pushed to the patient, and zero model calls
// occurred during the second turn.
func TestDoubleDraftBug_AwaitingReview_SecondMessageDoesNotRedraft(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	// --- Phase 1: complete the interview and draft the SOAP note. ---
	// First Complete() call is runInterviewTurn's generateInterviewTurn,
	// which emits the completion marker; the second is draftSOAPNote's model
	// call, which returns a well-formed SOAP note.
	client := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: ReadyForNoteMarker},
		{text: wellFormedSOAPText},
	}}
	physNotifier := &spyPhysicianNotifier{}
	patNotifier := &spyPatientNotifier{}

	var wg1 sync.WaitGroup
	wg1.Add(1)
	d1 := NewDrafter(client, s, physNotifier, patNotifier).WithOnComplete(wg1.Done)
	d1.DraftAsync(f.TenantID, f.Conv, f.Patient)
	wg1.Wait()

	// Sanity check: exactly one PENDING_REVIEW recommendation exists and the
	// conversation has moved to AWAITING_REVIEW (task 2.2 behaviour) before
	// we reproduce the bug scenario.
	convAfterDraft, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation after first draft: %v", err)
	}
	if convAfterDraft.CarePhase != store.CarePhaseAwaitingReview {
		t.Fatalf("care_phase after first draft = %q, want %q", convAfterDraft.CarePhase, store.CarePhaseAwaitingReview)
	}
	if got := countRecommendationsForConv(t, s, f.TenantID, f.Conv.ID, domain.StatePendingReview); got != 1 {
		t.Fatalf("expected 1 PENDING_REVIEW recommendation after the first draft, got %d", got)
	}

	// --- Phase 2: the patient sends another message while awaiting review. ---
	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "Actually it's gotten worse, what should I do?"); err != nil {
		t.Fatalf("create second patient message: %v", err)
	}

	modelCallsBeforeSecondTurn := client.idx

	var wg2 sync.WaitGroup
	wg2.Add(1)
	d2 := NewDrafter(client, s, physNotifier, patNotifier).WithOnComplete(wg2.Done)
	d2.DraftAsync(f.TenantID, convAfterDraft, f.Patient)
	wg2.Wait()

	// 1. Zero model calls during the second (AWAITING_REVIEW) turn. Because
	// sequentialClient errors once its scripted responses are exhausted, a
	// stray third Complete() call would also have surfaced as a draft
	// failure — checking idx directly makes the assertion explicit.
	if client.idx != modelCallsBeforeSecondTurn {
		t.Errorf("expected 0 model calls during the second turn, got %d", client.idx-modelCallsBeforeSecondTurn)
	}

	// 2. Exactly ONE recommendation exists for the conversation — no second
	// draft was created for the message sent during AWAITING_REVIEW.
	if got := countRecommendationsForConv(t, s, f.TenantID, f.Conv.ID, domain.StatePendingReview); got != 1 {
		t.Errorf("expected exactly 1 PENDING_REVIEW recommendation after the second message (no double draft), got %d", got)
	}
	if got := countRecommendationsForConv(t, s, f.TenantID, f.Conv.ID, domain.StateDraft); got != 0 {
		t.Errorf("expected 0 DRAFT recommendations, got %d", got)
	}

	// 3. The waiting message was persisted, with wording distinct from the
	// task-2.2 ack, as the second assistant message in the conversation.
	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	var assistantMsgs []store.Message
	for _, m := range msgs {
		if m.Role == "assistant" {
			assistantMsgs = append(assistantMsgs, m)
		}
	}
	if len(assistantMsgs) != 2 {
		t.Fatalf("expected 2 assistant messages (ack + reminder), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != ReviewPendingAckMessage {
		t.Errorf("first assistant message = %q, want the task-2.2 ReviewPendingAckMessage", assistantMsgs[0].Content)
	}
	if assistantMsgs[1].Content != ReviewPendingReminderMessage {
		t.Errorf("second assistant message = %q, want the task-2.3 ReviewPendingReminderMessage", assistantMsgs[1].Content)
	}
	if assistantMsgs[0].Content == assistantMsgs[1].Content {
		t.Error("the ack and the AWAITING_REVIEW reminder must use distinct wording")
	}

	// 4. The reminder was pushed to the patient (message.created, IDs only)
	// as the second patient notification overall.
	if patNotifier.count() != 2 {
		t.Fatalf("expected 2 patient notifications total (ack + reminder), got %d", patNotifier.count())
	}
	last := patNotifier.last()
	var evt map[string]any
	if err := json.Unmarshal(last.event, &evt); err != nil {
		t.Fatalf("unmarshal last patient event: %v", err)
	}
	if evt["type"] != "message.created" {
		t.Errorf("last event type = %q, want %q", evt["type"], "message.created")
	}
	data, _ := evt["data"].(map[string]any)
	if data["message_id"] != assistantMsgs[1].ID.String() {
		t.Errorf("last event message_id = %v, want %s (the reminder)", data["message_id"], assistantMsgs[1].ID)
	}
	if data["conversation_id"] != f.Conv.ID.String() {
		t.Errorf("last event conversation_id = %v, want %s", data["conversation_id"], f.Conv.ID)
	}

	// 5. The conversation must remain AWAITING_REVIEW — the reminder does not
	// cause any phase transition.
	convAfterSecondTurn, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation after second turn: %v", err)
	}
	if convAfterSecondTurn.CarePhase != store.CarePhaseAwaitingReview {
		t.Errorf("care_phase after second turn = %q, want %q", convAfterSecondTurn.CarePhase, store.CarePhaseAwaitingReview)
	}
}

// countRecommendationsForConv counts recommendations in the given state
// belonging to convID.
func countRecommendationsForConv(t *testing.T, s *store.Store, tenantID store.TenantID, convID uuid.UUID, state string) int {
	t.Helper()
	recs, err := s.ListRecommendationsByState(context.Background(), tenantID, state)
	if err != nil {
		t.Fatalf("list %s recommendations: %v", state, err)
	}
	count := 0
	for _, r := range recs {
		if r.ConversationID == convID {
			count++
		}
	}
	return count
}
