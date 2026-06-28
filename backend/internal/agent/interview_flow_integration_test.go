// Package agent — end-to-end integration tests for the full clinical interview
// → SOAP draft → physician review flow (Task 6.1).
//
// Uses "package agent" (internal tests) so the unexported runInterviewTurn,
// generateInterviewTurn, DefaultMaxInterviewTurns, ReadyForNoteMarker, and
// wellFormedSOAPText symbols are in scope. All DB-backed tests skip when
// TEST_DATABASE_URL is unset (consistent with the rest of the test suite).
//
// Scenarios covered:
//
//  1. Interview question turn: model returns no ReadyForNoteMarker → assistant
//     message persisted, patient notified, no recommendation created.
//  2. Note-ready turn: model returns ReadyForNoteMarker → soap_note
//     recommendation created at PENDING_REVIEW, physician notified via
//     queue.updated, patient notifier NOT called for that turn.
//  3. Physician approval: review.Execute approves the PENDING_REVIEW
//     recommendation → state transitions to DELIVERED atomically.
//  4. Turn-cap guard: conversation at DefaultMaxInterviewTurns assistant turns
//     forces a SOAP draft even when the model never emits ReadyForNoteMarker.
//
// Gap tests also addressed here:
//   - generateInterviewTurn store-error propagation (cancelled context).
package agent

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/review"
	"github.com/markolonius/housecall/backend/internal/store"
)

// Note: sequentialClient (a scripted-response ModelClient) is declared in
// carveout_test.go (same package). This file reuses it directly.

// ---------------------------------------------------------------------------
// integrationFixture — richer fixture that includes the physician so that
// review.Execute can be driven against the same tenant in the same test.
// ---------------------------------------------------------------------------

type integrationFixture struct {
	TenantID  store.TenantID
	Patient   store.Patient
	Physician store.Physician
	Conv      store.Conversation
}

// setupIntegrationFixture creates a tenant, a patient (state=CA), a physician
// licensed in CA, an active care relationship between them, a conversation, and
// one initial user message. Unique random suffixes prevent collisions when
// multiple test runs share the same DB without a TRUNCATE.
func setupIntegrationFixture(t *testing.T, s *store.Store) integrationFixture {
	t.Helper()
	ctx := context.Background()
	suffix := uuid.New().String()

	tenant, err := s.CreateTenant(ctx, "dtc", "integ-test-"+suffix)
	if err != nil {
		t.Fatalf("setupIntegrationFixture: create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient+" + suffix + "@integ.test",
		FullName:     "Integration Patient",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("setupIntegrationFixture: create patient: %v", err)
	}

	physician, err := s.CreatePhysician(ctx, tid, store.Physician{
		Email:          "doc+" + suffix + "@integ.test",
		FullName:       "Integration Physician",
		StatesLicensed: []string{"CA"},
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("setupIntegrationFixture: create physician: %v", err)
	}

	if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, physician.ID); err != nil {
		t.Fatalf("setupIntegrationFixture: create care relationship: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "integration test conversation")
	if err != nil {
		t.Fatalf("setupIntegrationFixture: create conversation: %v", err)
	}

	if _, err := s.CreateMessage(ctx, tid, conv.ID, "user", "I have a headache"); err != nil {
		t.Fatalf("setupIntegrationFixture: create initial user message: %v", err)
	}

	return integrationFixture{
		TenantID:  tid,
		Patient:   patient,
		Physician: physician,
		Conv:      conv,
	}
}

// ---------------------------------------------------------------------------
// TestInterviewFlow_EndToEnd — scenarios 1, 2, and 3.
// ---------------------------------------------------------------------------

// TestInterviewFlow_EndToEnd threads the realistic agent flow in one sequential
// test, sharing a single DB fixture across all three scenarios to mirror how
// the runtime actually processes a clinical conversation.
func TestInterviewFlow_EndToEnd(t *testing.T) {
	pool := itTestPool(t) // defined in interview_turn_test.go (same package)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	// -----------------------------------------------------------------------
	// Scenario 1: interview continues — model returns a plain question.
	// Expected: one assistant message persisted; patient notified; no
	// recommendation; no queue.updated to physicians.
	// -----------------------------------------------------------------------

	const interviewQuestion = "Can you describe where the pain is located?"

	physNotifier1 := &captureNotifier{} // defined in soap_drafter_test.go (same pkg)
	patNotifier1 := &spyPatientNotifier{} // defined in deliver_question_test.go (same pkg)

	d1 := NewDrafter(
		&sequentialClient{responses: []struct {
			text string
			err  error
		}{{text: interviewQuestion}}},
		s,
		physNotifier1,
		patNotifier1,
	)

	if err := d1.runInterviewTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("scenario 1: runInterviewTurn: %v", err)
	}

	// 1a. Exactly one assistant message persisted with the question text.
	msgs1, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("scenario 1: list messages: %v", err)
	}
	var assistantMsgs1 []store.Message
	for _, m := range msgs1 {
		if m.Role == "assistant" {
			assistantMsgs1 = append(assistantMsgs1, m)
		}
	}
	if len(assistantMsgs1) != 1 {
		t.Fatalf("scenario 1: expected 1 assistant message, got %d", len(assistantMsgs1))
	}
	if assistantMsgs1[0].Content != interviewQuestion {
		t.Errorf("scenario 1: assistant message = %q, want %q", assistantMsgs1[0].Content, interviewQuestion)
	}

	// 1b. Patient was notified with a message.created event carrying IDs only.
	if patNotifier1.count() != 1 {
		t.Fatalf("scenario 1: expected 1 patient notification, got %d", patNotifier1.count())
	}
	var patEvt1 map[string]any
	if err := json.Unmarshal(patNotifier1.last().event, &patEvt1); err != nil {
		t.Fatalf("scenario 1: unmarshal patient event: %v", err)
	}
	if patEvt1["type"] != "message.created" {
		t.Errorf("scenario 1: patient event type = %q, want %q", patEvt1["type"], "message.created")
	}

	// 1c. No recommendation row created (interview question is non-clinical).
	recs1, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("scenario 1: list PENDING_REVIEW recs: %v", err)
	}
	for _, r := range recs1 {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("scenario 1: unexpected PENDING_REVIEW recommendation for conversation %s", f.Conv.ID)
		}
	}
	drafts1, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StateDraft)
	if err != nil {
		t.Fatalf("scenario 1: list DRAFT recs: %v", err)
	}
	for _, r := range drafts1 {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("scenario 1: unexpected DRAFT recommendation for conversation %s", f.Conv.ID)
		}
	}

	// 1d. No queue.updated event emitted to physicians.
	if physNotifier1.count() != 0 {
		t.Errorf("scenario 1: expected 0 queue.updated events, got %d", physNotifier1.count())
	}

	// Add the patient's follow-up message to advance the conversation.
	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "The pain is on the right side of my head"); err != nil {
		t.Fatalf("create patient reply message: %v", err)
	}

	// -----------------------------------------------------------------------
	// Scenario 2: note-ready turn — model returns ReadyForNoteMarker.
	//
	// runInterviewTurn makes TWO model calls when ReadyForNote is true:
	//   call 1 (generateInterviewTurn): text containing ReadyForNoteMarker
	//   call 2 (draftSOAPNote):         wellFormedSOAPText
	//
	// Expected: PENDING_REVIEW soap_note recommendation persisted; physician
	// queue.updated fired; patient notifier NOT called this turn.
	// -----------------------------------------------------------------------

	physNotifier2 := &captureNotifier{}
	patNotifier2 := &spyPatientNotifier{}

	// The first call signals readiness; the second supplies the SOAP content.
	soapClient2 := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: ReadyForNoteMarker + "\nThis interview is complete."},
		{text: wellFormedSOAPText}, // from soap_drafter_test.go (same package)
	}}
	d2 := NewDrafter(soapClient2, s, physNotifier2, patNotifier2)

	if err := d2.runInterviewTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("scenario 2: runInterviewTurn: %v", err)
	}

	// 2a. Exactly one PENDING_REVIEW soap_note recommendation for this conversation.
	recs2, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("scenario 2: list PENDING_REVIEW recs: %v", err)
	}
	var pendingRec store.Recommendation
	for _, r := range recs2 {
		if r.ConversationID == f.Conv.ID {
			pendingRec = r
			break
		}
	}
	if pendingRec.ID == uuid.Nil {
		t.Fatalf("scenario 2: expected a PENDING_REVIEW recommendation, found none")
	}
	if pendingRec.PayloadType != domain.PayloadTypeSOAPNote {
		t.Errorf("scenario 2: payload_type = %q, want %q", pendingRec.PayloadType, domain.PayloadTypeSOAPNote)
	}

	// 2b. Payload JSON must contain all four SOAP sections including Objective.
	var sp domain.SOAPPayload
	if err := json.Unmarshal(pendingRec.Payload, &sp); err != nil {
		t.Fatalf("scenario 2: unmarshal SOAP payload: %v", err)
	}
	if sp.Subjective == "" {
		t.Error("scenario 2: payload.Subjective is empty")
	}
	if sp.Objective == "" {
		t.Error("scenario 2: payload.Objective is empty")
	}
	if sp.Assessment == "" {
		t.Error("scenario 2: payload.Assessment is empty")
	}
	if sp.Plan == "" {
		t.Error("scenario 2: payload.Plan is empty")
	}
	if err := sp.Validate(); err != nil {
		t.Errorf("scenario 2: SOAP payload fails domain validation: %v", err)
	}

	// 2c. Physician notifier received exactly one queue.updated event.
	if physNotifier2.count() != 1 {
		t.Fatalf("scenario 2: expected 1 queue.updated event, got %d", physNotifier2.count())
	}
	var physEvt map[string]any
	if err := json.Unmarshal(physNotifier2.last(), &physEvt); err != nil {
		t.Fatalf("scenario 2: unmarshal queue.updated event: %v", err)
	}
	if physEvt["type"] != "queue.updated" {
		t.Errorf("scenario 2: event type = %q, want %q", physEvt["type"], "queue.updated")
	}

	// 2d. Patient notifier must NOT have been called this turn — clinical content
	// (Assessment & Plan) must go through physician review before reaching the patient.
	if patNotifier2.count() != 0 {
		t.Errorf("scenario 2: expected 0 patient notifications for SOAP draft turn, got %d", patNotifier2.count())
	}

	// -----------------------------------------------------------------------
	// Scenario 3: physician approves the PENDING_REVIEW recommendation.
	//
	// review.Execute drives PENDING_REVIEW → APPROVED → DELIVERED atomically.
	// Expected: FinalState == DELIVERED; DB row durably in DELIVERED.
	// -----------------------------------------------------------------------

	result, err := review.Execute(ctx, s, f.TenantID, f.Physician.ID, pendingRec.ID, domain.ActionApprove, "")
	if err != nil {
		t.Fatalf("scenario 3: review.Execute: %v", err)
	}

	// 3a. Final state returned by Execute.
	if result.FinalState != domain.StateDelivered {
		t.Errorf("scenario 3: FinalState = %q, want %q", result.FinalState, domain.StateDelivered)
	}
	if result.RecommendationID != pendingRec.ID {
		t.Errorf("scenario 3: RecommendationID = %s, want %s", result.RecommendationID, pendingRec.ID)
	}

	// 3b. DB row is durably in DELIVERED state with reviewed_by set.
	fetched, err := s.GetRecommendation(ctx, f.TenantID, pendingRec.ID)
	if err != nil {
		t.Fatalf("scenario 3: GetRecommendation: %v", err)
	}
	if fetched.State != domain.StateDelivered {
		t.Errorf("scenario 3: DB state = %q, want %q", fetched.State, domain.StateDelivered)
	}
	if fetched.ReviewedBy == nil {
		t.Error("scenario 3: reviewed_by is nil after physician approval")
	} else if *fetched.ReviewedBy != f.Physician.ID {
		t.Errorf("scenario 3: reviewed_by = %s, want %s", *fetched.ReviewedBy, f.Physician.ID)
	}
}

// ---------------------------------------------------------------------------
// TestInterviewFlow_TurnCapForcesSOAPDraft — scenario 4.
// ---------------------------------------------------------------------------

// TestInterviewFlow_TurnCapForcesSOAPDraft verifies that a conversation already
// at DefaultMaxInterviewTurns assistant turns forces a SOAP draft even when the
// model output for that turn contains no ReadyForNoteMarker.
func TestInterviewFlow_TurnCapForcesSOAPDraft(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	// Seed exactly DefaultMaxInterviewTurns assistant-role messages so the cap
	// is reached before runInterviewTurn fires.
	for i := 0; i < DefaultMaxInterviewTurns; i++ {
		if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "assistant", "Prior question from agent"); err != nil {
			t.Fatalf("seed assistant message %d: %v", i, err)
		}
	}

	physNotifier := &captureNotifier{}
	patNotifier := &spyPatientNotifier{}

	// The model does NOT emit ReadyForNoteMarker on its first call, but the cap
	// is already reached. The runtime must therefore force a SOAP draft.
	// The second call (inside draftSOAPNote) returns a valid SOAP note.
	capClient := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: "How would you rate the pain on a scale of 0-10?"}, // no marker
		{text: wellFormedSOAPText},                                // used by forced draftSOAPNote
	}}
	d := NewDrafter(capClient, s, physNotifier, patNotifier)

	if err := d.runInterviewTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("runInterviewTurn at cap: %v", err)
	}

	// Forced SOAP draft must create a PENDING_REVIEW recommendation.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list PENDING_REVIEW recs: %v", err)
	}
	var found store.Recommendation
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			found = r
			break
		}
	}
	if found.ID == uuid.Nil {
		t.Fatal("expected PENDING_REVIEW soap_note recommendation after turn cap, found none")
	}
	if found.PayloadType != domain.PayloadTypeSOAPNote {
		t.Errorf("payload_type = %q, want %q", found.PayloadType, domain.PayloadTypeSOAPNote)
	}

	// Physician notifier must have received one queue.updated event.
	if physNotifier.count() != 1 {
		t.Errorf("expected 1 queue.updated event for forced SOAP draft, got %d", physNotifier.count())
	}

	// Patient notifier must NOT have fired — no interview question delivered;
	// clinical content requires physician review before reaching the patient.
	if patNotifier.count() != 0 {
		t.Errorf("expected 0 patient notifications for forced SOAP draft turn, got %d", patNotifier.count())
	}
}

// ---------------------------------------------------------------------------
// TestGenerateInterviewTurn_StoreError — gap test.
// ---------------------------------------------------------------------------

// TestGenerateInterviewTurn_StoreError verifies that a store error during
// generateInterviewTurn propagates to the caller and that the model client is
// never reached when the store call fails first (context cancelled).
func TestGenerateInterviewTurn_StoreError(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	f := itSetupConversation(t, s, []struct{ Role, Content string }{ // from interview_turn_test.go
		{"user", "I have a fever."},
	})

	// Cancel the context immediately so the very first store call
	// (ListMessagesByConversation) fails with a context error.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	spy := &spyClient{text: "Some follow-up question?"} // from interview_turn_test.go
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{}) // from interview_turn_test.go

	text, err := d.generateInterviewTurn(ctx, f.TenantID, f.Conv)
	if err == nil {
		t.Fatal("expected store error on cancelled context, got nil")
	}
	if text != "" {
		t.Errorf("expected empty text on store error, got %q", text)
	}
	// The model client must NOT have been called when the store fails first.
	if len(spy.captured) != 0 {
		t.Errorf("expected 0 model calls when store fails first, got %d", len(spy.captured))
	}
}
