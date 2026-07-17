// Package agent — integration tests for wiring red-flag triage into INTAKE
// dispatch (Task 5.2). Mirrors relay_flow_integration_test.go / carveout_test.go:
// "package agent" (internal tests) so the unexported runIntakeTurn,
// generateTriageTurn, runEmergentTurn, dispatchTurn, and task 5.1's
// TriageSystemPrompt/EmergentMarker/RoutineMarker/parseTriageTurn symbols are
// in scope. DB-backed tests skip when TEST_DATABASE_URL is unset, consistent
// with the rest of the suite.
//
// Scenarios covered (see
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Red-Flag Triage"):
//
//  1. Emergent message short-circuits: fixed emergency-referral message
//     persisted + pushed to patient, urgent queue.updated variant emitted,
//     audit event written, zero interview-turn model calls.
//  2. Routine message proceeds normally: interview turn runs exactly as
//     before triage existed.
//  3. Triage classifier failure (Complete() error) fails open: an
//     ai_interaction_failed audit is written and the interview turn still
//     runs.
//  4. Triage returns unparseable (non-error garbage) output: same fail-open
//     behaviour, its own audit reason.
//  5. AWAITING_REVIEW and PLAN_DELIVERED are unaffected by triage — quick
//     regression check on model call counts.
package agent

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ---------------------------------------------------------------------------
// triageSequentialClient: like sequentialClient (carveout_test.go) but also
// tracks the number of Complete() calls made, so tests can assert the
// interview-turn model call never happens after an EMERGENT triage result
// (rather than only inferring it from persisted messages).
// ---------------------------------------------------------------------------

type triageSequentialClient struct {
	mu        sync.Mutex
	responses []struct {
		text string
		err  error
	}
	idx   int
	calls int
}

func (c *triageSequentialClient) Complete(_ context.Context, _ []Message) (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.calls++
	if c.idx >= len(c.responses) {
		return "", &ParseError{Detail: "triageSequentialClient: no more responses"}
	}
	r := c.responses[c.idx]
	c.idx++
	return r.text, r.err
}

func (c *triageSequentialClient) callCount() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.calls
}

// assistantMessages filters msgs down to assistant-role rows, preserving order.
func assistantMessages(msgs []store.Message) []store.Message {
	var out []store.Message
	for _, m := range msgs {
		if m.Role == "assistant" {
			out = append(out, m)
		}
	}
	return out
}

// assertNoRecommendationForConversation asserts no DRAFT or PENDING_REVIEW
// recommendation exists for conv — the triage short-circuit and fail-open
// paths in this file must never create one.
func assertNoRecommendationForConversation(t *testing.T, s *store.Store, tenantID store.TenantID, convID uuid.UUID) {
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

// ---------------------------------------------------------------------------
// Scenario 1: an emergent message short-circuits the interview.
// ---------------------------------------------------------------------------

func TestRunIntakeTurn_Emergent_ShortCircuitsInterview(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "I have crushing chest pain and can't breathe"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	client := &triageSequentialClient{responses: []struct {
		text string
		err  error
	}{{text: EmergentMarker}}}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.runIntakeTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runIntakeTurn: unexpected error: %v", err)
	}

	// Exactly one model call (the triage call) — the interview-turn model
	// call must never happen for an emergent classification.
	if got := client.callCount(); got != 1 {
		t.Errorf("model Complete called %d times, want 1 (interview turn must not run)", got)
	}

	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	assistantMsgs := assistantMessages(msgs)
	if len(assistantMsgs) != 1 {
		t.Fatalf("expected 1 assistant message (emergency referral), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != EmergencyReferralMessage {
		t.Errorf("assistant message = %q, want fixed EmergencyReferralMessage", assistantMsgs[0].Content)
	}

	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the emergency referral, got %d", patNotifier.count())
	}
	if physNotifier.count() != 1 {
		t.Errorf("expected 1 urgent physician notification, got %d", physNotifier.count())
	}

	var evt map[string]any
	if err := json.Unmarshal(physNotifier.last(), &evt); err != nil {
		t.Fatalf("unmarshal physician event: %v", err)
	}
	if evt["type"] != "queue.updated" {
		t.Errorf("event type = %v, want %q", evt["type"], "queue.updated")
	}
	data, _ := evt["data"].(map[string]any)
	if data == nil {
		t.Fatalf("physician event missing data object: %s", physNotifier.last())
	}
	if data["priority"] != "urgent" {
		t.Errorf("data.priority = %v, want %q", data["priority"], "urgent")
	}
	if data["conversation_id"] != f.Conv.ID.String() {
		t.Errorf("data.conversation_id = %v, want %q", data["conversation_id"], f.Conv.ID.String())
	}

	assertNoRecommendationForConversation(t, s, f.TenantID, f.Conv.ID)

	// agent.emergent_triage audit event written, identifiers only.
	rows, err := pool.Query(ctx,
		`SELECT metadata FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'agent.emergent_triage'
		    AND metadata->>'conversation_id' = $2`,
		f.TenantID.UUID(), f.Conv.ID.String(),
	)
	if err != nil {
		t.Fatalf("query agent.emergent_triage audit rows: %v", err)
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
		for _, want := range []string{"conversation_id", "patient_id", "message_id"} {
			if _, ok := m[want]; !ok {
				t.Errorf("audit metadata missing %q", want)
			}
		}
		for _, forbidden := range []string{"content", "text", "message"} {
			if _, present := m[forbidden]; present {
				t.Errorf("audit metadata must not contain field %q (PHI leak)", forbidden)
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows error: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 agent.emergent_triage audit row, got %d", count)
	}

	// The conversation stays in INTAKE — an emergency short-circuit is not a
	// care-phase transition.
	convAfter, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if convAfter.CarePhase != store.CarePhaseIntake {
		t.Errorf("care_phase = %q, want %q", convAfter.CarePhase, store.CarePhaseIntake)
	}
}

// ---------------------------------------------------------------------------
// Scenario 2: a routine message proceeds to the interview turn as before.
// ---------------------------------------------------------------------------

func TestRunIntakeTurn_Routine_ProceedsToInterview(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "I have a mild headache since yesterday"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const interviewQuestion = "Can you describe where the pain is located?"
	client := &triageSequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: RoutineMarker},
		{text: interviewQuestion},
	}}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.runIntakeTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runIntakeTurn: unexpected error: %v", err)
	}

	if got := client.callCount(); got != 2 {
		t.Errorf("model Complete called %d times, want 2 (triage + interview)", got)
	}

	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	assistantMsgs := assistantMessages(msgs)
	if len(assistantMsgs) != 1 {
		t.Fatalf("expected 1 assistant message (the interview question), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != interviewQuestion {
		t.Errorf("assistant message = %q, want %q", assistantMsgs[0].Content, interviewQuestion)
	}

	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the interview question, got %d", patNotifier.count())
	}
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 physician notifications for a plain interview question, got %d", physNotifier.count())
	}

	assertNoRecommendationForConversation(t, s, f.TenantID, f.Conv.ID)
}

// ---------------------------------------------------------------------------
// Scenario 3: triage classifier failure (Complete() error) fails open.
// ---------------------------------------------------------------------------

func TestRunIntakeTurn_TriageClassifierError_FailsOpenToInterview(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "I have a mild headache"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const interviewQuestion = "On a scale of 0 to 10, how severe is the pain?"
	client := &triageSequentialClient{responses: []struct {
		text string
		err  error
	}{
		{err: &ModelError{StatusCode: 503}}, // triage call fails
		{text: interviewQuestion},           // interview call still runs
	}}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.runIntakeTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runIntakeTurn: unexpected error: %v", err)
	}

	if got := client.callCount(); got != 2 {
		t.Errorf("model Complete called %d times, want 2 (failed triage + successful interview)", got)
	}

	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	assistantMsgs := assistantMessages(msgs)
	if len(assistantMsgs) != 1 {
		t.Fatalf("expected 1 assistant message (the interview question), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != interviewQuestion {
		t.Errorf("assistant message = %q, want %q", assistantMsgs[0].Content, interviewQuestion)
	}
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the interview question, got %d", patNotifier.count())
	}

	assertTriageFailureAudit(t, pool, ctx, f.TenantID, f.Conv.ID.String(), "model_error")
}

// ---------------------------------------------------------------------------
// Scenario 4: triage returns unparseable output (not an error) — same
// fail-open behaviour, its own audit reason.
// ---------------------------------------------------------------------------

func TestRunIntakeTurn_TriageUnparseable_FailsOpenToInterview(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "I have a mild headache"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const interviewQuestion = "How long has the headache lasted?"
	client := &triageSequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: "sure, I can help with that today!"}, // garbage: neither marker
		{text: interviewQuestion},
	}}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.runIntakeTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runIntakeTurn: unexpected error: %v", err)
	}

	if got := client.callCount(); got != 2 {
		t.Errorf("model Complete called %d times, want 2 (unparseable triage + successful interview)", got)
	}

	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	assistantMsgs := assistantMessages(msgs)
	if len(assistantMsgs) != 1 {
		t.Fatalf("expected 1 assistant message (the interview question), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != interviewQuestion {
		t.Errorf("assistant message = %q, want %q", assistantMsgs[0].Content, interviewQuestion)
	}
	if patNotifier.count() != 1 {
		t.Errorf("expected 1 patient notification for the interview question, got %d", patNotifier.count())
	}

	assertTriageFailureAudit(t, pool, ctx, f.TenantID, f.Conv.ID.String(), "unparseable")
}

// assertTriageFailureAudit asserts exactly one ai_interaction_failed audit
// row for convID with stage="triage" and the given reason, and that no
// PHI-shaped field is present in its metadata.
func assertTriageFailureAudit(t *testing.T, pool *pgxpool.Pool, ctx context.Context, tenantID store.TenantID, convID string, wantReason string) {
	t.Helper()
	rows, err := pool.Query(ctx,
		`SELECT metadata FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'ai_interaction_failed'
		    AND metadata->>'conversation_id' = $2 AND metadata->>'stage' = 'triage'`,
		tenantID.UUID(), convID,
	)
	if err != nil {
		t.Fatalf("query ai_interaction_failed (triage) audit rows: %v", err)
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
		if got, ok := m["reason"].(string); !ok || got != wantReason {
			t.Errorf("audit reason = %v, want %q (metadata=%s)", m["reason"], wantReason, meta)
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
		t.Errorf("expected 1 ai_interaction_failed (stage=triage, reason=%s) audit row, got %d", wantReason, count)
	}
}

// ---------------------------------------------------------------------------
// Scenario 5: AWAITING_REVIEW and PLAN_DELIVERED are unaffected by triage.
// ---------------------------------------------------------------------------

// TestDispatchTurn_AwaitingReview_NoTriageCall asserts that a conversation in
// AWAITING_REVIEW never reaches runIntakeTurn/triage at all — the model is
// never called (mirrors runAwaitingReviewTurn's existing no-model-call
// contract).
func TestDispatchTurn_AwaitingReview_NoTriageCall(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	if err := s.Txn(ctx, func(tx *store.TxStore) error {
		return tx.TransitionCarePhase(ctx, f.TenantID, f.Conv.ID, store.CarePhaseIntake, store.CarePhaseAwaitingReview)
	}); err != nil {
		t.Fatalf("transition to AWAITING_REVIEW: %v", err)
	}
	conv, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}

	client := &triageSequentialClient{} // no responses scripted at all
	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.dispatchTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("dispatchTurn: unexpected error: %v", err)
	}

	if got := client.callCount(); got != 0 {
		t.Errorf("model Complete called %d times, want 0 for AWAITING_REVIEW (triage must not run)", got)
	}
}

// TestDispatchTurn_PlanDelivered_NoTriageCall asserts that a conversation in
// PLAN_DELIVERED makes exactly one model call (the relay call) — triage does
// not run an extra classification call ahead of it.
func TestDispatchTurn_PlanDelivered_NoTriageCall(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupRelayFixture(t, s)
	ctx := context.Background()

	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "What does twice daily mean?"); err != nil {
		t.Fatalf("create patient message: %v", err)
	}

	const explainText = "Twice daily means once in the morning and once in the evening."
	client := &triageSequentialClient{responses: []struct {
		text string
		err  error
	}{{text: explainText}}}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.dispatchTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("dispatchTurn: unexpected error: %v", err)
	}

	if got := client.callCount(); got != 1 {
		t.Errorf("model Complete called %d times, want 1 (relay only, no triage in PLAN_DELIVERED)", got)
	}
}
