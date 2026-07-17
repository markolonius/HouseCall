// Package agent — the flagship end-to-end integration test for the whole
// add-agent-care-loop change (Task 6.1). It walks the FULL care loop, in one
// long-lived conversation, through every phase introduced across Phases 1-5
// of this change:
//
//	intake -> ack -> physician reject with reason -> targeted re-interview ->
//	new draft -> approve -> deliver -> relay Q&A -> new complaint reopens
//	intake
//
// Every turn is driven through the real production dispatch entry point,
// dispatchTurn (the same function DraftAsync's goroutine calls in
// production — see drafter.go), so the care-phase branching under test is
// exactly the branching a real patient message triggers. The physician-side
// actions (reject-with-reason, approve) are driven through review.Execute,
// the same transport-agnostic function both the JSON API and the web portal
// call (see internal/review/review.go) — the identical pattern
// interview_flow_integration_test.go's Scenario 3 already uses for approval.
//
// A single scripted model client (e2eClient, defined below) is shared across
// the entire test so the call sequence is asserted end to end: triage now
// precedes every INTAKE-phase turn (Phase 5), including the turn that
// immediately follows a reopened-intake transition (reopenIntakeForNewComplaint
// calls runIntakeTurn, not runInterviewTurn directly), so those calls are
// counted alongside the interview/SOAP-draft/relay calls that existed before
// this change. See the step-by-step commentary inline for the full 12-call
// sequence.
//
// DB-backed: skips when TEST_DATABASE_URL is unset, consistent with the rest
// of the suite.
package agent

import (
	"context"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/review"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ---------------------------------------------------------------------------
// e2eClient — a scripted ModelClient shared across the whole walkthrough.
//
// Unlike sequentialClient (carveout_test.go), e2eClient also captures the
// message slice passed to every Complete() call (like spyClient in
// interview_turn_test.go) so the test can assert *what* context a specific
// call in the sequence received — needed for Step 4's "rejection reason
// reached the model" assertion. Unlike triageSequentialClient, exhausting
// the script calls t.Fatalf immediately (with the call index) rather than
// returning a ParseError, since a wrong call count anywhere in an 11-call
// sequence is a test-authoring bug worth failing loudly and precisely on.
// ---------------------------------------------------------------------------

type e2eScriptedResponse struct {
	// step documents which step of the walkthrough this call corresponds to
	// — purely for readable failure messages when the sequence drifts.
	step string
	text string
	err  error
}

type e2eClient struct {
	t         *testing.T
	mu        sync.Mutex
	responses []e2eScriptedResponse
	idx       int
	captured  [][]Message
}

func newE2EClient(t *testing.T, responses []e2eScriptedResponse) *e2eClient {
	return &e2eClient{t: t, responses: responses}
}

func (c *e2eClient) Complete(_ context.Context, msgs []Message) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	cp := make([]Message, len(msgs))
	copy(cp, msgs)
	c.captured = append(c.captured, cp)

	if c.idx >= len(c.responses) {
		c.t.Fatalf("e2eClient: Complete() call #%d has no scripted response (only %d scripted)", c.idx+1, len(c.responses))
	}
	r := c.responses[c.idx]
	c.idx++
	return r.text, r.err
}

// callCount returns the number of Complete() calls made so far.
func (c *e2eClient) callCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.idx
}

// messagesFor returns the captured message slice for the call at the given
// 1-based sequence position (matching the numbered steps in the test body's
// comments), failing the test with a clear message if that call never
// happened.
func (c *e2eClient) messagesFor(t *testing.T, callNumber int) []Message {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	if callNumber < 1 || callNumber > len(c.captured) {
		t.Fatalf("e2eClient: requested captured messages for call #%d, but only %d calls have happened", callNumber, len(c.captured))
	}
	return c.captured[callNumber-1]
}

// wellFormedSOAPText2 is a second, distinguishable well-formed SOAP note used
// for the revision drafted after the rejection (Step 4) — distinct content
// from wellFormedSOAPText (Step 1's draft) so the test can assert the two
// PENDING_REVIEW recommendations are genuinely separate rows with different
// draft content, not the same row re-used.
const wellFormedSOAPText2 = `SUBJECTIVE:
Patient reports the same right-sided throbbing headache has returned and is now worse. Confirms no current medications, consistent with the physician's request to clarify medication history before this revision.

OBJECTIVE:
None reported.

ASSESSMENT:
Revised assessment: unilateral throbbing headache with photophobia and phonophobia, migraine most likely, medication history now clarified per physician request; requires physician review before any diagnosis is confirmed.

PLAN:
Rest in a quiet dark room; stay well hydrated; OTC ibuprofen 400 mg every 6 hours as needed for pain, confirmed no interacting medications; seek emergency care if headache suddenly worsens, vision changes, or neurological symptoms appear; follow up with primary care within 48 hours if no improvement.`

// TestCareLoop_EndToEnd walks the entire care loop in one sequential test —
// the capstone integration test for openspec change add-agent-care-loop.
func TestCareLoop_EndToEnd(t *testing.T) {
	pool := itTestPool(t) // defined in interview_turn_test.go (same package)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s) // defined in interview_flow_integration_test.go (same package); seeds tenant/patient/physician/care-relationship/conversation + one initial user message ("I have a headache")
	ctx := context.Background()

	physNotifier := &captureNotifier{}   // defined in soap_drafter_test.go
	patNotifier := &spyPatientNotifier{} // defined in deliver_question_test.go

	const (
		interviewQuestion1 = "Can you describe where the pain is located?"
		relayExplainText   = "Every 6 hours means you can take another dose once six hours have passed since the last one — do not take it more often than that."
		newComplaintQ      = "Can you describe what the rash looks like — is it red, raised, or itchy?"
	)
	const rejectionReason = "ask about current medications before drafting a new plan"

	// The full 11-call scripted sequence. Each entry's `step` documents which
	// numbered walkthrough step (below) it belongs to.
	client := newE2EClient(t, []e2eScriptedResponse{
		// --- Step 1: intake -> ack (first patient message, already seeded) ---
		{step: "1a triage (routine)", text: RoutineMarker},
		{step: "1b interview question (no marker)", text: interviewQuestion1},
		// (patient sends a follow-up message here)
		{step: "1c triage (routine)", text: RoutineMarker},
		{step: "1d interview turn concludes", text: ReadyForNoteMarker + "\nThis interview is complete."},
		{step: "1e SOAP draft #1", text: wellFormedSOAPText},

		// --- Step 2: message during AWAITING_REVIEW makes NO model call ---
		// (nothing scripted here — runAwaitingReviewTurn must not call Complete)

		// --- Step 3: physician reject with reason — no model call (review.Execute) ---

		// --- Step 4: targeted re-interview -> new draft ---
		{step: "4a triage (routine)", text: RoutineMarker},
		{step: "4b interview turn concludes (with rejection guidance in context)", text: ReadyForNoteMarker + "\nThis interview is complete."},
		{step: "4c SOAP draft #2 (revision)", text: wellFormedSOAPText2},

		// --- Step 5: physician approves -> deliver — no model call (review.Execute) ---

		// --- Step 6: relay Q&A (clarifying question, grounded reply) ---
		{step: "6a relay explain reply", text: relayExplainText},

		// --- Step 7: new complaint reopens intake ---
		{step: "7a relay detects new complaint", text: NewComplaintMarker},
		{step: "7b triage on reopened intake (routine)", text: RoutineMarker},
		{step: "7c interview turn on reopened intake", text: newComplaintQ},
	})

	d := NewDrafter(client, s, physNotifier, patNotifier)

	// =========================================================================
	// STEP 1: intake -> ack. Two patient messages drive two INTAKE dispatchTurn
	// calls; the second concludes the interview and drafts a SOAP note.
	// =========================================================================

	// Turn A: the fixture's seeded first message ("I have a headache").
	// dispatchTurn -> runIntakeTurn: triage (routine) + interview-generate
	// (plain question, no marker).
	conv, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step1: GetConversation: %v", err)
	}
	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("step1 turnA: dispatchTurn: %v", err)
	}
	if got := client.callCount(); got != 2 {
		t.Fatalf("step1 turnA: model call count = %d, want 2 (triage + interview question)", got)
	}

	// Patient's follow-up message advances the conversation toward readiness.
	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "The pain is on the right side of my head"); err != nil {
		t.Fatalf("step1: create patient follow-up message: %v", err)
	}

	// Turn B: triage (routine) + interview-generate (ReadyForNoteMarker) +
	// SOAP draft. dispatchTurn re-reads care_phase itself but we must pass a
	// Conversation value with the current phase, so re-fetch first.
	conv, err = s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step1 turnB: GetConversation: %v", err)
	}
	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("step1 turnB: dispatchTurn: %v", err)
	}
	if got := client.callCount(); got != 5 {
		t.Fatalf("step1 turnB: cumulative model call count = %d, want 5 (turnA's 2 + triage + interview-ready + soap-draft)", got)
	}

	// Assertion: exactly one PENDING_REVIEW soap_note recommendation for this
	// conversation.
	recs1, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("step1: list PENDING_REVIEW recs: %v", err)
	}
	var rec1 store.Recommendation
	for _, r := range recs1 {
		if r.ConversationID == f.Conv.ID {
			rec1 = r
			break
		}
	}
	if rec1.ID == uuid.Nil {
		t.Fatal("step1: expected a PENDING_REVIEW recommendation after the interview concluded, found none")
	}
	if rec1.PayloadType != domain.PayloadTypeSOAPNote {
		t.Errorf("step1: payload_type = %q, want %q", rec1.PayloadType, domain.PayloadTypeSOAPNote)
	}

	// Assertion: the ack message is persisted — the LAST assistant message —
	// and contains none of the drafted SOAP content.
	convAfterDraft, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step1: GetConversation after draft: %v", err)
	}
	if convAfterDraft.CarePhase != store.CarePhaseAwaitingReview {
		t.Fatalf("step1: care_phase = %q, want %q", convAfterDraft.CarePhase, store.CarePhaseAwaitingReview)
	}

	msgsAfterStep1 := listAssistantMessages(t, s, f.TenantID, f.Conv.ID)
	if len(msgsAfterStep1) != 2 {
		t.Fatalf("step1: expected 2 assistant messages (turnA's question + the ack), got %d", len(msgsAfterStep1))
	}
	ackMsg := msgsAfterStep1[len(msgsAfterStep1)-1]
	if ackMsg.Content != ReviewPendingAckMessage {
		t.Errorf("step1: ack message content = %q, want the fixed ReviewPendingAckMessage", ackMsg.Content)
	}
	for _, forbidden := range []string{"SUBJECTIVE", "OBJECTIVE", "ASSESSMENT", "PLAN"} {
		if strings.Contains(ackMsg.Content, forbidden) {
			t.Errorf("step1: ack message unexpectedly contains SOAP section %q", forbidden)
		}
	}

	// =========================================================================
	// STEP 2: a patient message during AWAITING_REVIEW must not call the model
	// or create a second recommendation (the double-draft guard, task 2.3).
	// =========================================================================

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "Just checking in, any update?"); err != nil {
		t.Fatalf("step2: create patient message: %v", err)
	}
	conv, err = s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step2: GetConversation: %v", err)
	}
	if conv.CarePhase != store.CarePhaseAwaitingReview {
		t.Fatalf("step2: precondition failed, care_phase = %q, want AWAITING_REVIEW", conv.CarePhase)
	}
	callCountBeforeStep2 := client.callCount()
	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("step2: dispatchTurn: %v", err)
	}
	if got := client.callCount(); got != callCountBeforeStep2 {
		t.Fatalf("step2: model call count changed from %d to %d — AWAITING_REVIEW must make NO model call", callCountBeforeStep2, got)
	}

	// No second recommendation created for this conversation.
	recsStillPending, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("step2: list PENDING_REVIEW recs: %v", err)
	}
	var pendingCountForConv int
	for _, r := range recsStillPending {
		if r.ConversationID == f.Conv.ID {
			pendingCountForConv++
		}
	}
	if pendingCountForConv != 1 {
		t.Fatalf("step2: expected exactly 1 PENDING_REVIEW recommendation still outstanding, got %d", pendingCountForConv)
	}

	// The reminder message is the new last assistant message.
	msgsAfterStep2 := listAssistantMessages(t, s, f.TenantID, f.Conv.ID)
	if len(msgsAfterStep2) != 3 {
		t.Fatalf("step2: expected 3 assistant messages (question + ack + reminder), got %d", len(msgsAfterStep2))
	}
	reminderMsg := msgsAfterStep2[len(msgsAfterStep2)-1]
	if reminderMsg.Content != ReviewPendingReminderMessage {
		t.Errorf("step2: reminder message content = %q, want the fixed ReviewPendingReminderMessage", reminderMsg.Content)
	}

	// =========================================================================
	// STEP 3: physician rejects rec1 with a reason.
	// =========================================================================

	rejectResult, err := review.Execute(ctx, s, f.TenantID, f.Physician.ID, rec1.ID, domain.ActionReject, "", rejectionReason)
	if err != nil {
		t.Fatalf("step3: review.Execute reject: %v", err)
	}
	if rejectResult.FinalState != domain.StateRejected {
		t.Errorf("step3: FinalState = %q, want %q", rejectResult.FinalState, domain.StateRejected)
	}

	rec1AfterReject, err := s.GetRecommendation(ctx, f.TenantID, rec1.ID)
	if err != nil {
		t.Fatalf("step3: GetRecommendation: %v", err)
	}
	if rec1AfterReject.State != domain.StateRejected {
		t.Fatalf("step3: DB state = %q, want %q", rec1AfterReject.State, domain.StateRejected)
	}

	var gotReason *string
	if err := pool.QueryRow(ctx,
		`SELECT rejection_reason FROM recommendations WHERE tenant_id = $1 AND id = $2`,
		f.TenantID.UUID(), rec1.ID,
	).Scan(&gotReason); err != nil {
		t.Fatalf("step3: query rejection_reason: %v", err)
	}
	if gotReason == nil || *gotReason != rejectionReason {
		t.Fatalf("step3: rejection_reason = %v, want %q", gotReason, rejectionReason)
	}

	convAfterReject, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step3: GetConversation: %v", err)
	}
	if convAfterReject.CarePhase != store.CarePhaseIntake {
		t.Fatalf("step3: care_phase = %q, want %q", convAfterReject.CarePhase, store.CarePhaseIntake)
	}

	// =========================================================================
	// STEP 4: patient follow-up -> rejection reason reaches the model's
	// context -> interview concludes again -> a SECOND, separate SOAP
	// recommendation is drafted -> PENDING_REVIEW, AWAITING_REVIEW again.
	// =========================================================================

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "My headache is back and it's worse than before"); err != nil {
		t.Fatalf("step4: create patient follow-up message: %v", err)
	}
	conv, err = s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step4: GetConversation: %v", err)
	}
	if conv.CarePhase != store.CarePhaseIntake {
		t.Fatalf("step4: precondition failed, care_phase = %q, want INTAKE", conv.CarePhase)
	}

	callCountBeforeStep4 := client.callCount() // 5
	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("step4: dispatchTurn: %v", err)
	}
	if got := client.callCount(); got != callCountBeforeStep4+3 {
		t.Fatalf("step4: model call count = %d, want %d (triage + interview-ready + soap-draft)", got, callCountBeforeStep4+3)
	}

	// The interview-generate call is the SECOND of the three calls made in
	// this dispatchTurn invocation (triage first, then interview-generate,
	// then the SOAP draft) — call number callCountBeforeStep4+2 in the
	// client's 1-based sequence.
	interviewCallMsgs := client.messagesFor(t, callCountBeforeStep4+2)
	foundReason := false
	for _, m := range interviewCallMsgs {
		if strings.Contains(m.Content, rejectionReason) {
			foundReason = true
			break
		}
	}
	if !foundReason {
		t.Errorf("step4: expected the interview-turn model call to include the rejection reason %q in its context, but it did not", rejectionReason)
	}
	// The triage call immediately preceding it must NOT have seen the reason
	// (rejection guidance is interview-only context, per generateInterviewTurn's
	// doc comment).
	triageCallMsgs := client.messagesFor(t, callCountBeforeStep4+1)
	for _, m := range triageCallMsgs {
		if strings.Contains(m.Content, rejectionReason) {
			t.Errorf("step4: triage call unexpectedly contains the rejection reason — guidance must be interview-turn-only")
		}
	}

	// A second, separate PENDING_REVIEW soap_note recommendation now exists
	// for this conversation, distinct from rec1 (which is REJECTED).
	recs2, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("step4: list PENDING_REVIEW recs: %v", err)
	}
	var rec2 store.Recommendation
	for _, r := range recs2 {
		if r.ConversationID == f.Conv.ID {
			rec2 = r
			break
		}
	}
	if rec2.ID == uuid.Nil {
		t.Fatal("step4: expected a new PENDING_REVIEW recommendation after the revision interview concluded, found none")
	}
	if rec2.ID == rec1.ID {
		t.Fatal("step4: the new PENDING_REVIEW recommendation must be a distinct row from the rejected rec1")
	}
	if rec2.DraftContent == rec1.DraftContent {
		t.Error("step4: rec2's draft content should differ from rec1's (a genuinely new draft, not a resurrected one)")
	}

	convAfterRevisionDraft, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step4: GetConversation: %v", err)
	}
	if convAfterRevisionDraft.CarePhase != store.CarePhaseAwaitingReview {
		t.Fatalf("step4: care_phase = %q, want %q", convAfterRevisionDraft.CarePhase, store.CarePhaseAwaitingReview)
	}

	// The rejection reason must never appear verbatim in any patient-facing
	// message persisted so far (spec: "The rejection reason is not leaked to
	// the patient").
	for _, m := range listAllMessages(t, s, f.TenantID, f.Conv.ID) {
		if strings.Contains(m.Content, rejectionReason) {
			t.Errorf("step4: persisted message (role=%s) leaks the rejection reason verbatim", m.Role)
		}
	}

	// =========================================================================
	// STEP 5: physician approves rec2 -> DELIVERED, care_phase PLAN_DELIVERED.
	// =========================================================================

	approveResult, err := review.Execute(ctx, s, f.TenantID, f.Physician.ID, rec2.ID, domain.ActionApprove, "", "")
	if err != nil {
		t.Fatalf("step5: review.Execute approve: %v", err)
	}
	if approveResult.FinalState != domain.StateDelivered {
		t.Errorf("step5: FinalState = %q, want %q", approveResult.FinalState, domain.StateDelivered)
	}

	rec2AfterApprove, err := s.GetRecommendation(ctx, f.TenantID, rec2.ID)
	if err != nil {
		t.Fatalf("step5: GetRecommendation: %v", err)
	}
	if rec2AfterApprove.State != domain.StateDelivered {
		t.Fatalf("step5: DB state = %q, want %q", rec2AfterApprove.State, domain.StateDelivered)
	}

	convAfterDeliver, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step5: GetConversation: %v", err)
	}
	if convAfterDeliver.CarePhase != store.CarePhasePlanDelivered {
		t.Fatalf("step5: care_phase = %q, want %q", convAfterDeliver.CarePhase, store.CarePhasePlanDelivered)
	}

	// =========================================================================
	// STEP 6: patient asks a clarifying question -> relay replies grounded in
	// the delivered content -> care_phase stays PLAN_DELIVERED, no new
	// recommendation.
	// =========================================================================

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "What does every 6 hours mean exactly?"); err != nil {
		t.Fatalf("step6: create patient message: %v", err)
	}
	conv, err = s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step6: GetConversation: %v", err)
	}
	callCountBeforeStep6 := client.callCount()
	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("step6: dispatchTurn: %v", err)
	}
	if got := client.callCount(); got != callCountBeforeStep6+1 {
		t.Fatalf("step6: model call count = %d, want %d (one relay call, no triage in PLAN_DELIVERED)", got, callCountBeforeStep6+1)
	}

	msgsAfterStep6 := listAllMessages(t, s, f.TenantID, f.Conv.ID)
	lastMsg := msgsAfterStep6[len(msgsAfterStep6)-1]
	if lastMsg.Role != "assistant" || lastMsg.Content != relayExplainText {
		t.Errorf("step6: last message = {role=%s, content=%q}, want {role=assistant, content=%q}", lastMsg.Role, lastMsg.Content, relayExplainText)
	}

	convAfterRelay, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step6: GetConversation: %v", err)
	}
	if convAfterRelay.CarePhase != store.CarePhasePlanDelivered {
		t.Fatalf("step6: care_phase = %q, want %q (relay reply must not transition)", convAfterRelay.CarePhase, store.CarePhasePlanDelivered)
	}

	// No new recommendation (DRAFT or PENDING_REVIEW) created by the relay reply.
	assertNoNewRecommendation(t, s, f.TenantID, f.Conv.ID, []string{rec1.ID.String(), rec2.ID.String()})

	// =========================================================================
	// STEP 7: patient reports a new complaint -> care_phase transitions back
	// to INTAKE and an interview turn runs (question persisted) — without
	// requiring a further patient message.
	// =========================================================================

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "Actually, I also have a new rash on my arm that started today"); err != nil {
		t.Fatalf("step7: create patient message: %v", err)
	}
	conv, err = s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step7: GetConversation: %v", err)
	}
	if conv.CarePhase != store.CarePhasePlanDelivered {
		t.Fatalf("step7: precondition failed, care_phase = %q, want PLAN_DELIVERED", conv.CarePhase)
	}
	callCountBeforeStep7 := client.callCount()
	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("step7: dispatchTurn: %v", err)
	}
	// Three calls: the relay call that detects the new complaint, then the
	// triage call and the interview-turn call that follow (the reopened
	// conversation goes through runIntakeTurn like any other INTAKE-phase
	// turn — a new complaint against a delivered plan must be screened for
	// emergency presentations, not skip straight to the interview).
	if got := client.callCount(); got != callCountBeforeStep7+3 {
		t.Fatalf("step7: model call count = %d, want %d (relay detection + triage + interview turn)", got, callCountBeforeStep7+3)
	}

	convAfterNewComplaint, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("step7: GetConversation: %v", err)
	}
	if convAfterNewComplaint.CarePhase != store.CarePhaseIntake {
		t.Fatalf("step7: care_phase = %q, want %q", convAfterNewComplaint.CarePhase, store.CarePhaseIntake)
	}

	msgsAfterStep7 := listAllMessages(t, s, f.TenantID, f.Conv.ID)
	lastMsgStep7 := msgsAfterStep7[len(msgsAfterStep7)-1]
	if lastMsgStep7.Role != "assistant" || lastMsgStep7.Content != newComplaintQ {
		t.Errorf("step7: last message = {role=%s, content=%q}, want {role=assistant, content=%q}", lastMsgStep7.Role, lastMsgStep7.Content, newComplaintQ)
	}
	if strings.Contains(lastMsgStep7.Content, NewComplaintMarker) {
		t.Error("step7: the new-complaint marker itself must never reach a patient-facing message")
	}

	// Final sanity: the whole walkthrough made exactly 12 model calls, in the
	// exact order scripted at the top of this test.
	if got := client.callCount(); got != 12 {
		t.Errorf("care loop end-to-end: total model calls = %d, want 12", got)
	}
}

// ---------------------------------------------------------------------------
// Local helpers
// ---------------------------------------------------------------------------

// listAllMessages fetches and returns every message for convID, in stored order.
func listAllMessages(t *testing.T, s *store.Store, tenantID store.TenantID, convID uuid.UUID) []store.Message {
	t.Helper()
	msgs, err := s.ListMessagesByConversation(context.Background(), tenantID, convID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	return msgs
}

// listAssistantMessages fetches every message for convID and filters it down
// to assistant-role rows, preserving order.
func listAssistantMessages(t *testing.T, s *store.Store, tenantID store.TenantID, convID uuid.UUID) []store.Message {
	t.Helper()
	var out []store.Message
	for _, m := range listAllMessages(t, s, tenantID, convID) {
		if m.Role == "assistant" {
			out = append(out, m)
		}
	}
	return out
}

// assertNoNewRecommendation asserts that no DRAFT or PENDING_REVIEW
// recommendation exists for convID other than the given known IDs — used
// after the relay reply (step 6) to prove it created nothing new.
func assertNoNewRecommendation(t *testing.T, s *store.Store, tenantID store.TenantID, convID uuid.UUID, knownIDs []string) {
	t.Helper()
	ctx := context.Background()
	known := make(map[string]bool, len(knownIDs))
	for _, id := range knownIDs {
		known[id] = true
	}
	for _, state := range []string{domain.StateDraft, domain.StatePendingReview} {
		recs, err := s.ListRecommendationsByState(ctx, tenantID, state)
		if err != nil {
			t.Fatalf("list %s recs: %v", state, err)
		}
		for _, r := range recs {
			if r.ConversationID == convID && !known[r.ID.String()] {
				t.Errorf("unexpected new %s recommendation %s for conversation %s", state, r.ID, convID)
			}
		}
	}
}
