// Package agent — internal tests asserting the delivery carve-out (Task 3.2).
//
// The carve-out is the security-sensitive invariant that separates the two
// classes of agent output:
//
//   - Interview questions (non-clinical, direct): delivered to the patient as
//     assistant messages via deliverInterviewQuestion. No recommendation row is
//     ever created for these turns.
//   - SOAP notes (clinical, review-gated): created exclusively via draftSOAPNote
//     as a soap_note recommendation in PENDING_REVIEW. The patient is NEVER
//     notified by the agent when a SOAP note is drafted.
//
// The agent has no code path that transitions a recommendation to APPROVED,
// MODIFIED, or DELIVERED — those transitions are physician-only.
//
// Uses "package agent" to access the unexported runInterviewTurn symbol.
// DB-backed tests reuse itTestPool from interview_turn_test.go (same package).
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

// ---------------------------------------------------------------------------
// sequentialClient: stub that returns a pre-programmed sequence of responses.
// Used when runInterviewTurn makes two model calls (interview turn + SOAP draft).
// ---------------------------------------------------------------------------

type sequentialClient struct {
	mu        sync.Mutex
	responses []struct {
		text string
		err  error
	}
	idx int
}

func (s *sequentialClient) Complete(_ context.Context, _ []Message) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.idx >= len(s.responses) {
		return "", &ParseError{Detail: "sequentialClient: no more responses"}
	}
	r := s.responses[s.idx]
	s.idx++
	return r.text, r.err
}

// ---------------------------------------------------------------------------
// carveoutFixture — minimum DB rows for carve-out testing: one tenant, one
// patient with a CA physician-linked care relationship, and one conversation
// with one user message.
// ---------------------------------------------------------------------------

type carveoutFixture struct {
	TenantID store.TenantID
	Patient  store.Patient
	Conv     store.Conversation
}

func setupCarveoutFixture(t *testing.T, s *store.Store) carveoutFixture {
	t.Helper()
	ctx := context.Background()
	suffix := uuid.New().String()

	tenant, err := s.CreateTenant(ctx, "dtc", "carveout-test-"+suffix)
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient+" + suffix + "@carveout.test",
		FullName:     "Carveout Test Patient",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	// A physician is required for DRAFT→PENDING_REVIEW via domain.Transition
	// (the agent actor path skips state-licensing but the care relationship
	// must exist for downstream physician review tests).
	physician, err := s.CreatePhysician(ctx, tid, store.Physician{
		Email:          "doc+" + suffix + "@carveout.test",
		FullName:       "Carveout Doc",
		StatesLicensed: []string{"CA"},
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("create physician: %v", err)
	}
	if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, physician.ID); err != nil {
		t.Fatalf("create care relationship: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "carveout test conversation")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	if _, err := s.CreateMessage(ctx, tid, conv.ID, "user", "I have a headache"); err != nil {
		t.Fatalf("create message: %v", err)
	}

	return carveoutFixture{TenantID: tid, Patient: patient, Conv: conv}
}

// ---------------------------------------------------------------------------
// spyPhysicianNotifier records SendToPhysicians calls.
// ---------------------------------------------------------------------------

type spyPhysicianNotifier struct {
	mu     sync.Mutex
	events [][]byte
}

func (n *spyPhysicianNotifier) SendToPhysicians(_ string, event []byte) {
	cp := make([]byte, len(event))
	copy(cp, event)
	n.mu.Lock()
	defer n.mu.Unlock()
	n.events = append(n.events, cp)
}

func (n *spyPhysicianNotifier) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.events)
}

// ---------------------------------------------------------------------------
// spyPatientNotifierCarveout records SendToPatient calls.
// (Named distinctly from the one in deliver_question_test.go to avoid
// redeclaration — both live in "package agent".)
// ---------------------------------------------------------------------------

type spyPatientNotifierCarveout struct {
	mu    sync.Mutex
	calls int
}

func (n *spyPatientNotifierCarveout) SendToPatient(_, _ string, _ []byte) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls++
}

func (n *spyPatientNotifierCarveout) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return n.calls
}

// ---------------------------------------------------------------------------
// Test: question turn — patient notified, no recommendation created.
// ---------------------------------------------------------------------------

// TestRunInterviewTurn_Question_PatientNotified_NoRecommendation asserts the
// carve-out for the interview-continues branch of runInterviewTurn:
//
//   - When decideInterviewAction yields a question (no marker, cap not reached),
//     runInterviewTurn MUST persist the question as an assistant message and
//     call the patient notifier exactly once.
//   - runInterviewTurn MUST NOT create any recommendation row.
//   - The physician notifier MUST NOT be called (no queue.updated event).
func TestRunInterviewTurn_Question_PatientNotified_NoRecommendation(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupCarveoutFixture(t, s)
	ctx := context.Background()

	// A plain interview question — no ReadyForNoteMarker.
	const question = "Can you describe the character of the pain — is it sharp, dull, or throbbing?"

	physSpy := &spyPhysicianNotifier{}
	patSpy := &spyPatientNotifierCarveout{}
	d := NewDrafter(&spyClient{text: question}, s, physSpy, patSpy)

	if err := d.runInterviewTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runInterviewTurn: unexpected error: %v", err)
	}

	// 1. No recommendation must be created.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list PENDING_REVIEW recs: %v", err)
	}
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("interview question turn must not create a recommendation (found payload_type=%q)", r.PayloadType)
		}
	}
	drafts, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StateDraft)
	if err != nil {
		t.Fatalf("list DRAFT recs: %v", err)
	}
	for _, r := range drafts {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("unexpected DRAFT recommendation for conversation %s", f.Conv.ID)
		}
	}

	// 2. An assistant message carrying the question must be persisted.
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
		t.Fatalf("expected 1 assistant message (interview question), got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != question {
		t.Errorf("assistant message content = %q, want %q", assistantMsgs[0].Content, question)
	}

	// 3. Patient notifier must be called exactly once.
	if patSpy.count() != 1 {
		t.Errorf("patient notifier called %d times, want 1", patSpy.count())
	}

	// 4. Physician notifier must NOT be called.
	if physSpy.count() != 0 {
		t.Errorf("physician notifier called %d times for an interview-question turn, want 0", physSpy.count())
	}
}

// ---------------------------------------------------------------------------
// Test: ReadyForNote turn — soap_note in PENDING_REVIEW, patient NOT notified.
// ---------------------------------------------------------------------------

// TestRunInterviewTurn_ReadyForNote_SOAPNoteInPendingReview_PatientNotNotified
// asserts the carve-out for the SOAP note branch of runInterviewTurn:
//
//   - When decideInterviewAction yields ReadyForNote (marker detected), the agent
//     runtime MUST draft a soap_note recommendation → PENDING_REVIEW.
//   - The physician notifier MUST receive a queue.updated event.
//   - The patient notifier MUST NOT be called (clinical A/P is never delivered
//     by the agent — only by a physician's APPROVE/MODIFY→DELIVER transition).
func TestRunInterviewTurn_ReadyForNote_SOAPNoteInPendingReview_PatientNotNotified(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupCarveoutFixture(t, s)
	ctx := context.Background()

	// Call 1 (generateInterviewTurn): model emits ReadyForNoteMarker.
	// Call 2 (draftSOAPNote): model returns a well-formed SOAP note.
	client := &sequentialClient{
		responses: []struct {
			text string
			err  error
		}{
			{text: ReadyForNoteMarker},
			{text: wellFormedSOAPText}, // from soap_drafter_test.go (same package)
		},
	}

	physSpy := &spyPhysicianNotifier{}
	patSpy := &spyPatientNotifierCarveout{}
	d := NewDrafter(client, s, physSpy, patSpy)

	if err := d.runInterviewTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runInterviewTurn: unexpected error: %v", err)
	}

	// 1. Exactly one soap_note recommendation in PENDING_REVIEW.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list PENDING_REVIEW recs: %v", err)
	}
	var found []store.Recommendation
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			found = append(found, r)
		}
	}
	if len(found) != 1 {
		t.Fatalf("expected 1 soap_note PENDING_REVIEW recommendation, got %d", len(found))
	}
	rec := found[0]
	if rec.PayloadType != domain.PayloadTypeSOAPNote {
		t.Errorf("payload_type = %q, want %q", rec.PayloadType, domain.PayloadTypeSOAPNote)
	}

	// 2. Payload must be parseable as a valid SOAPPayload.
	var sp domain.SOAPPayload
	if err := json.Unmarshal(rec.Payload, &sp); err != nil {
		t.Fatalf("unmarshal soap payload: %v", err)
	}
	if err := sp.Validate(); err != nil {
		t.Errorf("soap payload fails validation: %v", err)
	}

	// 3. No DRAFT rows must remain (DRAFT→PENDING_REVIEW was atomic).
	drafts, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StateDraft)
	if err != nil {
		t.Fatalf("list DRAFT recs: %v", err)
	}
	for _, r := range drafts {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("unexpected DRAFT recommendation — DRAFT→PENDING_REVIEW must be atomic")
		}
	}

	// 4. Physician notifier must receive a queue.updated event.
	if physSpy.count() == 0 {
		t.Fatal("physician notifier not called — queue.updated must be emitted when soap_note is drafted")
	}

	// 5. Patient notifier MUST NOT be called. This is the core of the carve-out:
	//    clinical content (Assessment & Plan) never reaches the patient via the
	//    agent — only via the physician lifecycle (APPROVE/MODIFY → DELIVER).
	if patSpy.count() != 0 {
		t.Errorf("patient notifier called %d times during soap_note drafting — CARVE-OUT VIOLATED: "+
			"clinical content must not be delivered to the patient by the agent", patSpy.count())
	}

	// 6. No assistant message must be persisted for the SOAP-note turn —
	//    the note goes into the recommendation row, not the message history.
	msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	for _, m := range msgs {
		if m.Role == "assistant" {
			t.Errorf("unexpected assistant message during SOAP-note turn: role=%q content-length=%d "+
				"— SOAP content must not be written to the message history by the agent",
				m.Role, len(m.Content))
		}
	}
}

// ---------------------------------------------------------------------------
// Guard test: the agent actor has NO domain transition to APPROVED, MODIFIED,
// or DELIVERED. These transitions are physician-only.
// ---------------------------------------------------------------------------

// TestAgentHasNoDeliveryTransition asserts that domain.Transition rejects any
// attempt by an agent actor to move a recommendation to APPROVED, MODIFIED, or
// DELIVERED. This is a compile-and-logic guard: even if runInterviewTurn were
// accidentally extended to call domain.Transition with those actions, the domain
// layer would reject it.
func TestAgentHasNoDeliveryTransition(t *testing.T) {
	agentActor := domain.Actor{Type: domain.ActorAgent, ID: uuid.Nil}
	const patientState = "CA"

	// The agent CAN go DRAFT → PENDING_REVIEW (its only permitted transition).
	_, err := domain.Transition(domain.StateDraft, domain.ActionSubmitForReview, agentActor, patientState)
	if err != nil {
		t.Errorf("agent DRAFT→PENDING_REVIEW must be permitted, got error: %v", err)
	}

	// The agent MUST NOT be able to Approve.
	_, err = domain.Transition(domain.StatePendingReview, domain.ActionApprove, agentActor, patientState)
	if err == nil {
		t.Error("agent must not be permitted to Approve a recommendation — CARVE-OUT VIOLATED")
	}

	// The agent MUST NOT be able to Modify.
	_, err = domain.Transition(domain.StatePendingReview, domain.ActionModify, agentActor, patientState)
	if err == nil {
		t.Error("agent must not be permitted to Modify a recommendation — CARVE-OUT VIOLATED")
	}

	// The agent MUST NOT be able to Deliver.
	_, err = domain.Transition(domain.StateApproved, domain.ActionDeliver, agentActor, patientState)
	if err == nil {
		t.Error("agent must not be permitted to Deliver a recommendation — CARVE-OUT VIOLATED")
	}

	// The agent MUST NOT be able to Reject.
	_, err = domain.Transition(domain.StatePendingReview, domain.ActionReject, agentActor, patientState)
	if err == nil {
		t.Error("agent must not be permitted to Reject a recommendation — CARVE-OUT VIOLATED")
	}
}
