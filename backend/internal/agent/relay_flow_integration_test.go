// Package agent — integration tests for the PLAN_DELIVERED post-approval plan
// relay (Task 4.2). Mirrors interview_flow_integration_test.go / carveout_test.go:
// "package agent" (internal tests) so the unexported runPlanDeliveredTurn,
// generateRelayTurn, deliverRelayReply, reopenIntakeForNewComplaint, and
// task 4.1's RelaySystemPrompt/NewComplaintMarker/parseRelayTurn symbols are
// in scope. DB-backed tests skip when TEST_DATABASE_URL is unset, consistent
// with the rest of the suite.
//
// Scenarios covered (see
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Post-Approval Plan Relay"):
//
//  1. Clarifying question answered: model returns explanation text grounded in
//     the delivered plan -> persisted as an assistant message, phase stays
//     PLAN_DELIVERED, no new recommendation.
//  2. Off-plan question deferred: mechanically identical to (1) at this layer
//     — RelayOutcome does not distinguish an explanation from a deferral (see
//     relay_outcome.go's doc comment); the choice is entirely prompt-driven
//     (RelaySystemPrompt rules 1-2), not something the parser or runtime
//     branches on. Kept as a separate test to document that equivalence
//     explicitly and exercise deferral-shaped text.
//  3. New complaint reopens intake: model returns NewComplaintMarker -> the
//     conversation transitions PLAN_DELIVERED -> INTAKE and runs an intake
//     turn immediately — triage first, then the interview — against the
//     conversation history that already includes the new-complaint message.
//  4. Model failure in PLAN_DELIVERED: ai_interaction_failed audit written, no
//     patient message, no care-phase transition.
package agent

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ---------------------------------------------------------------------------
// relayFixture — a PLAN_DELIVERED-ready conversation with one DELIVERED
// guidance recommendation carrying known final_content.
// ---------------------------------------------------------------------------

// relayDeliveredPlanContent is the fixed "final_content" every relay test
// grounds its model context on.
const relayDeliveredPlanContent = "Rest, drink fluids, and take acetaminophen every 6 hours as needed for pain. Follow up if symptoms worsen or you develop a fever above 102F."

type relayFixture struct {
	TenantID store.TenantID
	Patient  store.Patient
	Conv     store.Conversation
}

// setupRelayFixture builds on setupIntegrationFixture's tenant/patient/
// conversation shape (interview_flow_integration_test.go, same package),
// then seeds one DELIVERED guidance recommendation with known final_content
// and moves the conversation's care_phase directly to PLAN_DELIVERED — the
// state runPlanDeliveredTurn expects on entry.
//
// The DELIVERED state and phase transitions are written directly via store
// methods rather than driven through the full agent-draft/physician-review
// pipeline: only the resulting state matters for these tests, and
// TestInterviewFlow_EndToEnd's Scenario 3 (interview_flow_integration_test.go)
// already covers the approval path that produces DELIVERED in production.
func setupRelayFixture(t *testing.T, s *store.Store) relayFixture {
	t.Helper()
	ctx := context.Background()
	f := setupIntegrationFixture(t, s)

	if err := s.Txn(ctx, func(tx *store.TxStore) error {
		rec, err := tx.CreateRecommendation(ctx, f.TenantID, store.Recommendation{
			ConversationID: f.Conv.ID,
			PatientID:      f.Patient.ID,
			State:          domain.StateDraft,
			PayloadType:    "guidance",
			Payload:        []byte(`{}`),
			DraftContent:   relayDeliveredPlanContent,
		})
		if err != nil {
			return err
		}
		finalContent := relayDeliveredPlanContent
		if err := tx.UpdateRecommendationState(ctx, f.TenantID, rec.ID, domain.StateDelivered, &f.Physician.ID, &finalContent); err != nil {
			return err
		}
		if err := tx.TransitionCarePhase(ctx, f.TenantID, f.Conv.ID, store.CarePhaseIntake, store.CarePhaseAwaitingReview); err != nil {
			return err
		}
		return tx.TransitionCarePhase(ctx, f.TenantID, f.Conv.ID, store.CarePhaseAwaitingReview, store.CarePhasePlanDelivered)
	}); err != nil {
		t.Fatalf("setupRelayFixture: seed delivered recommendation: %v", err)
	}

	conv, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("setupRelayFixture: GetConversation: %v", err)
	}

	return relayFixture{TenantID: f.TenantID, Patient: f.Patient, Conv: conv}
}

// ---------------------------------------------------------------------------
// Scenario 1: the agent explains the delivered plan.
// ---------------------------------------------------------------------------

// TestRunPlanDeliveredTurn_ExplainReply_PersistedNoTransition asserts the
// "agent explains the delivered plan" scenario: a clarifying question about
// the delivered plan gets the model's grounded explanation persisted as an
// assistant message, the conversation stays in PLAN_DELIVERED, and no
// recommendation is created.
func TestRunPlanDeliveredTurn_ExplainReply_PersistedNoTransition(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupRelayFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "What does twice daily mean?"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const explainText = "Twice daily means take the medication once in the morning and once in the evening, as your plan specified."
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(&spyClient{text: explainText}, s, physNotifier, patNotifier)

	if err := d.runPlanDeliveredTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runPlanDeliveredTurn: unexpected error: %v", err)
	}

	assertRelayReplyPersisted(t, s, f, explainText)

	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the explain reply, got %d", patNotifier.count())
	}
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 physician notifications for a relay reply, got %d", physNotifier.count())
	}
}

// ---------------------------------------------------------------------------
// Scenario 2: questions beyond the plan are deferred.
// ---------------------------------------------------------------------------

// TestRunPlanDeliveredTurn_DeferralReply_PersistedNoTransition asserts the
// "questions beyond the plan are deferred" scenario. This exercises the
// exact same runPlanDeliveredTurn -> deliverRelayReply code path as
// TestRunPlanDeliveredTurn_ExplainReply_PersistedNoTransition above:
// RelayOutcome does not distinguish an explanation from a deferral (see
// relay_outcome.go's doc comment) — the choice between them is entirely
// prompt-driven behaviour (RelaySystemPrompt rules 1-2), not something the
// parser or the runtime branches on. This test exists to document that
// mechanical equivalence explicitly using deferral-shaped text.
func TestRunPlanDeliveredTurn_DeferralReply_PersistedNoTransition(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupRelayFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "Can I take ibuprofen instead of the medication in the plan?"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const deferralText = "That's a question for your physician — I can pass it along."
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(&spyClient{text: deferralText}, s, physNotifier, patNotifier)

	if err := d.runPlanDeliveredTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runPlanDeliveredTurn: unexpected error: %v", err)
	}

	assertRelayReplyPersisted(t, s, f, deferralText)

	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the deferral reply, got %d", patNotifier.count())
	}
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 physician notifications for a relay reply, got %d", physNotifier.count())
	}
}

// assertRelayReplyPersisted is the shared assertion body for scenarios 1 and
// 2: exactly one assistant message with the given text, care_phase still
// PLAN_DELIVERED, and no recommendation created for the conversation.
func assertRelayReplyPersisted(t *testing.T, s *store.Store, f relayFixture, wantText string) {
	t.Helper()
	ctx := context.Background()

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
	if len(assistantMsgs) != 1 {
		t.Fatalf("expected 1 assistant message (relay reply), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != wantText {
		t.Errorf("assistant message content = %q, want %q", assistantMsgs[0].Content, wantText)
	}

	convAfter, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if convAfter.CarePhase != store.CarePhasePlanDelivered {
		t.Errorf("care_phase = %q, want %q (relay reply must not transition)", convAfter.CarePhase, store.CarePhasePlanDelivered)
	}

	for _, state := range []string{domain.StateDraft, domain.StatePendingReview} {
		recs, err := s.ListRecommendationsByState(ctx, f.TenantID, state)
		if err != nil {
			t.Fatalf("list %s recs: %v", state, err)
		}
		for _, r := range recs {
			if r.ConversationID == f.Conv.ID {
				t.Errorf("unexpected %s recommendation for conversation %s", state, f.Conv.ID)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Scenario 3: a new complaint reopens intake.
// ---------------------------------------------------------------------------

// TestRunPlanDeliveredTurn_NewComplaint_ReopensIntakeAndRunsTriageThenInterviewTurn
// asserts the "a new complaint reopens intake" scenario: when the relay
// model signals NewComplaintMarker, the conversation's care_phase moves
// PLAN_DELIVERED -> INTAKE and the reopened conversation is screened by the
// red-flag triage classifier before the interview turn runs — the same
// runIntakeTurn dispatch every other INTAKE-phase turn goes through (see
// ai-agent-runtime spec.md, "Red-Flag Triage": no carve-out for the
// reopened-intake path). A new complaint raised against a delivered plan is
// exactly the kind of message the triage screen exists to catch. Uses
// triageSequentialClient (triage_dispatch_test.go, same package) so the
// model call count can be asserted directly rather than only inferred from
// persisted messages.
func TestRunPlanDeliveredTurn_NewComplaint_ReopensIntakeAndRunsTriageThenInterviewTurn(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupRelayFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "Actually, I also have a new rash on my arm that started today"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const interviewQuestion = "Can you describe what the rash looks like — is it red, raised, or itchy?"
	client := &triageSequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: NewComplaintMarker}, // relay call: detects the new complaint
		{text: RoutineMarker},      // triage call on the reopened INTAKE turn
		{text: interviewQuestion},  // follow-up interview call
	}}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.runPlanDeliveredTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runPlanDeliveredTurn: unexpected error: %v", err)
	}

	// Three model calls: the relay call, the triage call, and the interview
	// call — the reopened conversation must go through triage, not jump
	// straight from the relay call to the interview call.
	if got := client.callCount(); got != 3 {
		t.Errorf("model Complete called %d times, want 3 (relay + triage + interview)", got)
	}

	// Care phase must have moved to INTAKE.
	convAfter, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if convAfter.CarePhase != store.CarePhaseIntake {
		t.Errorf("care_phase = %q, want %q", convAfter.CarePhase, store.CarePhaseIntake)
	}

	// The interview turn must have proceeded: exactly one assistant message
	// carrying the interview question — never the NewComplaintMarker itself.
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
	if len(assistantMsgs) != 1 {
		t.Fatalf("expected 1 assistant message (the follow-up interview question), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != interviewQuestion {
		t.Errorf("assistant message content = %q, want %q", assistantMsgs[0].Content, interviewQuestion)
	}

	// Patient notified exactly once for the interview question.
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the interview question, got %d", patNotifier.count())
	}
	// No queue.updated — the interview question turn does not draft a note.
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 physician notifications, got %d", physNotifier.count())
	}

	// No new recommendation created by this turn.
	for _, state := range []string{domain.StateDraft, domain.StatePendingReview} {
		recs, err := s.ListRecommendationsByState(ctx, f.TenantID, state)
		if err != nil {
			t.Fatalf("list %s recs: %v", state, err)
		}
		for _, r := range recs {
			if r.ConversationID == f.Conv.ID {
				t.Errorf("unexpected %s recommendation for conversation %s", state, f.Conv.ID)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Scenario 4: model failure in PLAN_DELIVERED.
// ---------------------------------------------------------------------------

// TestDraftAsync_PlanDelivered_ModelFailure_AuditWrittenNoPatientMessage
// asserts that a model failure during a PLAN_DELIVERED relay turn writes an
// ai_interaction_failed audit event, delivers no message to the patient, and
// leaves the conversation's care_phase unchanged — mirroring the failure
// discipline used elsewhere in the drafter (runInterviewTurn/draftSOAPNote).
// Driven through DraftAsync (not runPlanDeliveredTurn directly) so the audit
// write is exercised through the same path production traffic uses.
func TestDraftAsync_PlanDelivered_ModelFailure_AuditWrittenNoPatientMessage(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupRelayFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "Is this normal?"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}

	var wg sync.WaitGroup
	wg.Add(1)
	d := NewDrafter(&spyClient{err: &ModelError{StatusCode: 503}}, s, physNotifier, patNotifier).WithOnComplete(wg.Done)

	d.DraftAsync(f.TenantID, f.Conv, f.Patient)
	wg.Wait()

	// No assistant message persisted for this turn.
	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	for _, m := range msgs {
		if m.Role == "assistant" {
			t.Errorf("unexpected assistant message on model failure: message_id=%s", m.ID)
		}
	}

	// Patient notifier must not be called.
	if patNotifier.count() != 0 {
		t.Errorf("expected 0 patient notifications on model failure, got %d", patNotifier.count())
	}

	// care_phase must remain PLAN_DELIVERED — a failed relay turn does not
	// transition the conversation.
	convAfter, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if convAfter.CarePhase != store.CarePhasePlanDelivered {
		t.Errorf("care_phase = %q, want %q (failure must not transition)", convAfter.CarePhase, store.CarePhasePlanDelivered)
	}

	// Exactly one ai_interaction_failed audit row with reason "model_error"
	// and no PHI/model-body fields.
	rows, err := pool.Query(ctx,
		`SELECT metadata FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'ai_interaction_failed'
		    AND metadata->>'conversation_id' = $2`,
		f.TenantID.UUID(), f.Conv.ID.String(),
	)
	if err != nil {
		t.Fatalf("query ai_interaction_failed audit rows: %v", err)
	}
	defer rows.Close()

	var count int
	for rows.Next() {
		count++
		var meta []byte
		if err := rows.Scan(&meta); err != nil {
			t.Fatalf("scan audit metadata: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(meta, &m); err != nil {
			t.Fatalf("unmarshal audit metadata: %v", err)
		}
		if got, ok := m["reason"].(string); !ok || got != "model_error" {
			t.Errorf("audit reason = %v, want %q (metadata=%s)", m["reason"], "model_error", meta)
		}
		if _, ok := m["conversation_id"]; !ok {
			t.Errorf("audit metadata missing conversation_id")
		}
		if _, ok := m["patient_id"]; !ok {
			t.Errorf("audit metadata missing patient_id")
		}
		for _, forbidden := range []string{"body", "content", "text", "error", "detail", "message"} {
			if _, present := m[forbidden]; present {
				t.Errorf("audit metadata must not contain field %q (PHI/body leak)", forbidden)
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows error: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 ai_interaction_failed audit row, got %d", count)
	}

	// No queue.updated emitted.
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 queue.updated events on failure, got %d", physNotifier.count())
	}
}
