// Package agent — internal tests for draftSOAPNote and parseSOAPSections
// (Task 2.2).
//
// This file uses "package agent" (not "package agent_test") so it can access
// the unexported draftSOAPNote and parseSOAPSections symbols. DB-backed tests
// reuse itTestPool from interview_turn_test.go (same package) and the
// spyClient/stubNotifierNoop helpers defined there.
package agent

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ---------------------------------------------------------------------------
// Well-formed SOAP text used across multiple test cases.
// ---------------------------------------------------------------------------

const wellFormedSOAPText = `SUBJECTIVE:
Patient reports a throbbing headache on the right side that started two days ago. Rates severity 7/10. Worse with bright light and noise. Lying in a dark room provides partial relief. No prior headaches of this severity. Takes no regular medications. No known drug allergies.

OBJECTIVE:
None reported.

ASSESSMENT:
Preliminary assessment: unilateral throbbing headache with photophobia and phonophobia, consistent with migraine headache; requires physician review before any diagnosis is confirmed.

PLAN:
Rest in a quiet dark room; stay well hydrated; OTC ibuprofen 400 mg every 6 hours as needed for pain; seek emergency care if headache suddenly worsens, vision changes, or neurological symptoms appear; follow up with primary care within 48 hours if no improvement.`

// ---------------------------------------------------------------------------
// soapDrafterFixture — minimum DB rows for draftSOAPNote testing.
// A physician / care relationship is NOT required: the agent transition
// DRAFT→PENDING_REVIEW ignores patient state for licensing.
// ---------------------------------------------------------------------------

type soapDrafterFixture struct {
	TenantID store.TenantID
	Patient  store.Patient
	Conv     store.Conversation
}

func setupSOAPDrafterFixture(t *testing.T, s *store.Store) soapDrafterFixture {
	t.Helper()
	ctx := context.Background()
	suffix := uuid.New().String()

	tenant, err := s.CreateTenant(ctx, "dtc", "soap-drafter-test-"+suffix)
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient+" + suffix + "@soap.test",
		FullName:     "SOAP Test Patient",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "soap test conversation")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	if _, err := s.CreateMessage(ctx, tid, conv.ID, "user", "I have a headache for two days"); err != nil {
		t.Fatalf("create message: %v", err)
	}

	return soapDrafterFixture{TenantID: tid, Patient: patient, Conv: conv}
}

// ---------------------------------------------------------------------------
// captureNotifier satisfies PhysicianNotifier and PatientNotifier, recording
// every physician event sent. Patient events are discarded (not exercised in
// SOAP drafter tests).
// ---------------------------------------------------------------------------

type captureNotifier struct {
	mu     sync.Mutex
	events [][]byte
}

func (n *captureNotifier) SendToPhysicians(_ string, event []byte) {
	n.mu.Lock()
	defer n.mu.Unlock()
	cp := make([]byte, len(event))
	copy(cp, event)
	n.events = append(n.events, cp)
}

func (n *captureNotifier) SendToPatient(_, _ string, _ []byte) {}

func (n *captureNotifier) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.events)
}

func (n *captureNotifier) last() []byte {
	n.mu.Lock()
	defer n.mu.Unlock()
	if len(n.events) == 0 {
		return nil
	}
	return n.events[len(n.events)-1]
}

// ---------------------------------------------------------------------------
// Pure unit tests: parseSOAPSections
// ---------------------------------------------------------------------------

// TestParseSOAPSections_HappyPath verifies that a well-formed four-section
// model output is parsed into the correct SOAPPayload fields.
func TestParseSOAPSections_HappyPath(t *testing.T) {
	p, err := parseSOAPSections(wellFormedSOAPText)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if p.Subjective == "" {
		t.Error("Subjective is empty")
	}
	if p.Objective == "" {
		t.Error("Objective is empty")
	}
	if p.Assessment == "" {
		t.Error("Assessment is empty")
	}
	if p.Plan == "" {
		t.Error("Plan is empty")
	}
}

// TestParseSOAPSections_MissingSectionLabel verifies that output missing at
// least one label returns a *ParseError and no panic.
func TestParseSOAPSections_MissingSectionLabel(t *testing.T) {
	// PLAN section is absent.
	missing := `SUBJECTIVE:
Patient reports headache.

OBJECTIVE:
None reported.

ASSESSMENT:
Preliminary assessment: tension headache; physician review required.`

	_, err := parseSOAPSections(missing)
	if err == nil {
		t.Fatal("expected error for output missing PLAN section, got nil")
	}
	var pe *ParseError
	if !errAsParseError(err, &pe) {
		t.Errorf("expected *ParseError, got %T: %v", err, err)
	}
}

// TestParseSOAPSections_InlineContent verifies that content placed on the same
// line as the header (after the colon) is correctly extracted.
func TestParseSOAPSections_InlineContent(t *testing.T) {
	inline := `SUBJECTIVE: Headache onset two days ago.
OBJECTIVE: None reported.
ASSESSMENT: Preliminary assessment: tension headache.
PLAN: Rest and OTC ibuprofen.`

	p, err := parseSOAPSections(inline)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if p.Subjective != "Headache onset two days ago." {
		t.Errorf("Subjective = %q, want %q", p.Subjective, "Headache onset two days ago.")
	}
	if p.Objective != "None reported." {
		t.Errorf("Objective = %q, want %q", p.Objective, "None reported.")
	}
	if p.Plan != "Rest and OTC ibuprofen." {
		t.Errorf("Plan = %q, want %q", p.Plan, "Rest and OTC ibuprofen.")
	}
}

// TestParseSOAPSections_CaseInsensitiveLabels verifies that lowercase or
// mixed-case section headers are matched correctly.
func TestParseSOAPSections_CaseInsensitiveLabels(t *testing.T) {
	lower := `subjective:
Patient has a cough.

objective:
None reported.

assessment:
Preliminary assessment: viral upper respiratory tract infection.

plan:
Rest and fluids.`

	p, err := parseSOAPSections(lower)
	if err != nil {
		t.Fatalf("unexpected error for lowercase labels: %v", err)
	}
	if p.Subjective == "" || p.Objective == "" || p.Assessment == "" || p.Plan == "" {
		t.Errorf("one or more sections empty with lowercase labels: %+v", p)
	}
}

// TestParseSOAPSections_WhitespaceOnlyContent verifies that parseSOAPSections
// returns an empty string for whitespace-only section content (after TrimSpace)
// and that the domain validator subsequently rejects it.
func TestParseSOAPSections_WhitespaceOnlyContent(t *testing.T) {
	// Subjective section contains only blank lines.
	ws := `SUBJECTIVE:


OBJECTIVE:
None reported.

ASSESSMENT:
Preliminary assessment: unknown.

PLAN:
Follow up with primary care.`

	p, err := parseSOAPSections(ws)
	if err != nil {
		t.Fatalf("parseSOAPSections must not error on whitespace-only content: %v", err)
	}
	// After TrimSpace the Subjective should be empty string.
	if p.Subjective != "" {
		t.Errorf("expected empty Subjective after trimming whitespace, got %q", p.Subjective)
	}
	// Validate must reject the whitespace-only section.
	if err := p.Validate(); err == nil {
		t.Fatal("expected Validate() to reject whitespace-only Subjective, got nil")
	}
}

// errAsParseError is a type-assertion helper for *ParseError.
func errAsParseError(err error, target **ParseError) bool {
	if err == nil {
		return false
	}
	pe, ok := err.(*ParseError)
	if ok && target != nil {
		*target = pe
	}
	return ok
}

// ---------------------------------------------------------------------------
// DB-backed integration tests: draftSOAPNote
// ---------------------------------------------------------------------------

// TestDraftSOAPNote_HappyPath verifies that draftSOAPNote, given a stub client
// returning well-formed SOAP text, persists exactly one PENDING_REVIEW
// soap_note recommendation with the correct payload and draft_content, writes
// an audit event with payload_type in metadata, and emits queue.updated.
func TestDraftSOAPNote_HappyPath(t *testing.T) {
	pool := itTestPool(t) // defined in interview_turn_test.go, same package
	s := store.New(pool)
	f := setupSOAPDrafterFixture(t, s)
	ctx := context.Background()

	notifier := &captureNotifier{}
	// spyClient is defined in interview_turn_test.go (same package).
	client := &spyClient{text: wellFormedSOAPText}
	d := NewDrafter(client, s, notifier, notifier)

	if err := d.draftSOAPNote(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("draftSOAPNote: unexpected error: %v", err)
	}

	// 1. Exactly one PENDING_REVIEW recommendation for this conversation.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list recommendations: %v", err)
	}
	var found []store.Recommendation
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			found = append(found, r)
		}
	}
	if len(found) != 1 {
		t.Fatalf("expected 1 PENDING_REVIEW soap_note recommendation, got %d", len(found))
	}
	rec := found[0]

	// 2. payload_type must be soap_note.
	if rec.PayloadType != domain.PayloadTypeSOAPNote {
		t.Errorf("payload_type = %q, want %q", rec.PayloadType, domain.PayloadTypeSOAPNote)
	}

	// 3. Payload must contain all four sections.
	var sp domain.SOAPPayload
	if err := json.Unmarshal(rec.Payload, &sp); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if sp.Subjective == "" {
		t.Error("payload.subjective is empty")
	}
	if sp.Objective == "" {
		t.Error("payload.objective is empty")
	}
	if sp.Assessment == "" {
		t.Error("payload.assessment is empty")
	}
	if sp.Plan == "" {
		t.Error("payload.plan is empty")
	}
	if err := sp.Validate(); err != nil {
		t.Errorf("payload fails domain validation: %v", err)
	}

	// 4. draft_content must equal the full trimmed model text.
	wantDraftContent := strings.TrimSpace(wellFormedSOAPText)
	if rec.DraftContent != wantDraftContent {
		t.Errorf("draft_content length got=%d, want=%d", len(rec.DraftContent), len(wantDraftContent))
	}

	// 5. No DRAFT rows must remain (the transition was atomic).
	drafts, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StateDraft)
	if err != nil {
		t.Fatalf("list draft recs: %v", err)
	}
	for _, r := range drafts {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("unexpected DRAFT recommendation for conversation %s", f.Conv.ID)
		}
	}

	// 6. Audit event must include payload_type and identifiers — no PHI.
	rows, err := pool.Query(ctx,
		`SELECT metadata
		   FROM audit_events
		  WHERE tenant_id = $1
		    AND event_type = 'recommendation.submitted_for_review'
		    AND metadata->>'conversation_id' = $2`,
		f.TenantID.UUID(),
		f.Conv.ID.String(),
	)
	if err != nil {
		t.Fatalf("query audit events: %v", err)
	}
	defer rows.Close()

	var auditCount int
	for rows.Next() {
		auditCount++
		var meta []byte
		if err := rows.Scan(&meta); err != nil {
			t.Fatalf("scan audit metadata: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(meta, &m); err != nil {
			t.Fatalf("unmarshal audit metadata: %v", err)
		}
		if got, _ := m["payload_type"].(string); got != domain.PayloadTypeSOAPNote {
			t.Errorf("audit metadata payload_type = %q, want %q", got, domain.PayloadTypeSOAPNote)
		}
		if _, ok := m["recommendation_id"]; !ok {
			t.Error("audit metadata missing recommendation_id")
		}
		if _, ok := m["conversation_id"]; !ok {
			t.Error("audit metadata missing conversation_id")
		}
		// Clinical content must NOT appear in audit metadata.
		raw := string(meta)
		for _, forbidden := range []string{"throbbing", "ibuprofen", "headache", "Preliminary"} {
			if strings.Contains(raw, forbidden) {
				t.Errorf("audit metadata contains clinical content (found %q) — PHI constraint violation", forbidden)
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows error: %v", err)
	}
	if auditCount != 1 {
		t.Errorf("expected 1 audit event for recommendation.submitted_for_review, got %d", auditCount)
	}

	// 7. queue.updated must be emitted (draftSOAPNote is synchronous).
	if notifier.count() == 0 {
		t.Fatal("queue.updated event not emitted")
	}
	var evt map[string]any
	if err := json.Unmarshal(notifier.last(), &evt); err != nil {
		t.Fatalf("unmarshal queue.updated event: %v", err)
	}
	if evt["type"] != "queue.updated" {
		t.Errorf("event type = %q, want %q", evt["type"], "queue.updated")
	}
}

// TestDraftSOAPNote_MissingSection verifies that when the model output is
// missing a required section header, draftSOAPNote returns an error and
// persists no recommendation and emits no queue.updated.
func TestDraftSOAPNote_MissingSection(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupSOAPDrafterFixture(t, s)
	ctx := context.Background()

	// Model returns text without a PLAN section.
	malformedText := `SUBJECTIVE:
Patient reports a cough for three days.

OBJECTIVE:
None reported.

ASSESSMENT:
Preliminary assessment: upper respiratory tract infection; physician review required.`

	notifier := &captureNotifier{}
	d := NewDrafter(&spyClient{text: malformedText}, s, notifier, notifier)

	err := d.draftSOAPNote(ctx, f.TenantID, f.Conv, f.Patient)
	if err == nil {
		t.Fatal("expected error when model output is missing a SOAP section, got nil")
	}

	// No recommendation must be persisted.
	recs, listErr := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if listErr != nil {
		t.Fatalf("list recommendations: %v", listErr)
	}
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("found unexpected PENDING_REVIEW recommendation for conversation %s", f.Conv.ID)
		}
	}

	// No queue.updated must be emitted.
	if notifier.count() != 0 {
		t.Errorf("expected 0 queue.updated events on parse error, got %d", notifier.count())
	}

	// No ack message must be persisted — the parse failure happens before the
	// transaction that would write the ack even opens.
	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	for _, m := range msgs {
		if m.Role == "assistant" {
			t.Errorf("unexpected assistant message after parse failure: %q", m.Content)
		}
	}

	// The conversation's care phase must remain INTAKE.
	conv, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if conv.CarePhase != store.CarePhaseIntake {
		t.Errorf("care_phase = %q after parse failure, want %q", conv.CarePhase, store.CarePhaseIntake)
	}
}

// ---------------------------------------------------------------------------
// Task 2.2: review-pending acknowledgement + INTAKE→AWAITING_REVIEW
// ---------------------------------------------------------------------------

// TestDraftSOAPNote_PersistsAck_TransitionsPhase_NotifiesPatient verifies that
// a successful draftSOAPNote commit:
//   - persists the fixed ReviewPendingAckMessage as an assistant message in
//     the same conversation, and that message reveals none of the drafted
//     Subjective/Objective/Assessment/Plan content,
//   - moves the conversation's care_phase from INTAKE to AWAITING_REVIEW, and
//   - pushes exactly one message.created WS event to the patient, referencing
//     the ack message's id, only after the commit.
func TestDraftSOAPNote_PersistsAck_TransitionsPhase_NotifiesPatient(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupSOAPDrafterFixture(t, s)
	ctx := context.Background()

	physNotifier := &captureNotifier{}
	patNotifier := &recordingPatientNotifierSOAP{}
	client := &spyClient{text: wellFormedSOAPText}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	if err := d.draftSOAPNote(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("draftSOAPNote: unexpected error: %v", err)
	}

	// The recommendation payload — used below to assert the ack does not leak it.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list recommendations: %v", err)
	}
	var rec store.Recommendation
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			rec = r
		}
	}
	if rec.ID == uuid.Nil {
		t.Fatal("expected a PENDING_REVIEW recommendation, found none")
	}
	var sp domain.SOAPPayload
	if err := json.Unmarshal(rec.Payload, &sp); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}

	// 1. The ack must be persisted as an assistant message in the conversation.
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
		t.Fatalf("expected 1 assistant message (the ack), got %d", len(assistantMsgs))
	}
	ackMsg := assistantMsgs[0]
	if ackMsg.Content != ReviewPendingAckMessage {
		t.Errorf("ack content = %q, want fixed ReviewPendingAckMessage", ackMsg.Content)
	}

	// 2. The ack must not reveal any of the drafted SOAP content.
	for _, forbidden := range []string{sp.Subjective, sp.Objective, sp.Assessment, sp.Plan} {
		if forbidden != "" && strings.Contains(ackMsg.Content, forbidden) {
			t.Errorf("ack message leaks drafted SOAP content: found %q", forbidden)
		}
	}

	// 3. The conversation's care phase must now be AWAITING_REVIEW.
	conv, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if conv.CarePhase != store.CarePhaseAwaitingReview {
		t.Errorf("care_phase = %q, want %q", conv.CarePhase, store.CarePhaseAwaitingReview)
	}

	// 4. The patient must have been notified exactly once, with the ack's
	// message id — and only after the commit (the recommendation and phase
	// transition above are already durably visible by the time we assert this).
	if patNotifier.count() != 1 {
		t.Fatalf("expected 1 patient notification (the ack), got %d", patNotifier.count())
	}
	var evt map[string]any
	if err := json.Unmarshal(patNotifier.last(), &evt); err != nil {
		t.Fatalf("unmarshal patient event: %v", err)
	}
	if evt["type"] != "message.created" {
		t.Errorf("event type = %q, want %q", evt["type"], "message.created")
	}
	data, _ := evt["data"].(map[string]any)
	if data["message_id"] != ackMsg.ID.String() {
		t.Errorf("event message_id = %v, want %s", data["message_id"], ackMsg.ID)
	}
	if data["conversation_id"] != f.Conv.ID.String() {
		t.Errorf("event conversation_id = %v, want %s", data["conversation_id"], f.Conv.ID)
	}
}

// TestDraftSOAPNote_CASFailureAbortsWholeTransaction reproduces the race the
// INTAKE→AWAITING_REVIEW compare-and-swap is meant to guard: the conversation
// passed to draftSOAPNote observed CarePhaseIntake, but by the time the
// transaction runs, the row has already moved to AWAITING_REVIEW (e.g. a
// concurrent draft, or task 2.3's double-draft guard closing a race window).
// TransitionCarePhase's CAS then fails with store.ErrNotFound, which must
// abort and roll back the ENTIRE transaction: no recommendation persisted, no
// ack message persisted — nothing partial.
func TestDraftSOAPNote_CASFailureAbortsWholeTransaction(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupSOAPDrafterFixture(t, s)
	ctx := context.Background()

	// Simulate the race: move the conversation to AWAITING_REVIEW out from
	// under the (stale) f.Conv value, which still reports CarePhaseIntake.
	if err := s.Txn(ctx, func(tx *store.TxStore) error {
		return tx.TransitionCarePhase(ctx, f.TenantID, f.Conv.ID, store.CarePhaseIntake, store.CarePhaseAwaitingReview)
	}); err != nil {
		t.Fatalf("simulate race: %v", err)
	}

	physNotifier := &captureNotifier{}
	patNotifier := &recordingPatientNotifierSOAP{}
	client := &spyClient{text: wellFormedSOAPText}
	d := NewDrafter(client, s, physNotifier, patNotifier)

	err := d.draftSOAPNote(ctx, f.TenantID, f.Conv, f.Patient)
	if err == nil {
		t.Fatal("expected error from CAS failure, got nil")
	}
	if !errors.Is(err, store.ErrNotFound) {
		t.Errorf("expected store.ErrNotFound (CAS failure), got %T: %v", err, err)
	}

	// No recommendation of any kind must exist for this conversation.
	for _, state := range []string{domain.StateDraft, domain.StatePendingReview} {
		recs, listErr := s.ListRecommendationsByState(ctx, f.TenantID, state)
		if listErr != nil {
			t.Fatalf("list %s recommendations: %v", state, listErr)
		}
		for _, r := range recs {
			if r.ConversationID == f.Conv.ID {
				t.Errorf("unexpected %s recommendation after CAS failure — transaction was not atomic", state)
			}
		}
	}

	// No ack message must be persisted.
	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	for _, m := range msgs {
		if m.Role == "assistant" {
			t.Errorf("unexpected assistant message after CAS failure: %q", m.Content)
		}
	}

	// Neither notifier must have fired — nothing committed.
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 queue.updated events after CAS failure, got %d", physNotifier.count())
	}
	if patNotifier.count() != 0 {
		t.Errorf("expected 0 patient notifications after CAS failure, got %d", patNotifier.count())
	}

	// The conversation must remain in AWAITING_REVIEW (the state set up by the
	// simulated race) — draftSOAPNote's failed attempt must not have touched it.
	conv, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("GetConversation: %v", err)
	}
	if conv.CarePhase != store.CarePhaseAwaitingReview {
		t.Errorf("care_phase = %q, want %q (untouched by the failed transaction)", conv.CarePhase, store.CarePhaseAwaitingReview)
	}
}

// recordingPatientNotifierSOAP is a PatientNotifier that records every
// SendToPatient call. Named distinctly from recordingPatientNotifier in
// drafter_test.go ("package agent_test") to avoid confusion — this one lives
// in "package agent".
type recordingPatientNotifierSOAP struct {
	mu    sync.Mutex
	calls [][]byte
}

func (n *recordingPatientNotifierSOAP) SendToPatient(_, _ string, event []byte) {
	cp := make([]byte, len(event))
	copy(cp, event)
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls = append(n.calls, cp)
}

func (n *recordingPatientNotifierSOAP) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.calls)
}

func (n *recordingPatientNotifierSOAP) last() []byte {
	n.mu.Lock()
	defer n.mu.Unlock()
	if len(n.calls) == 0 {
		return nil
	}
	return n.calls[len(n.calls)-1]
}
