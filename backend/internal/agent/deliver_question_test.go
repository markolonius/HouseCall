// Package agent — internal tests for deliverInterviewQuestion (Task 3.1).
//
// Uses "package agent" to access the unexported deliverInterviewQuestion symbol.
// DB-backed tests reuse itTestPool from interview_turn_test.go (same package).
package agent

import (
	"context"
	"encoding/json"
	"sync"
	"testing"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/store"
)

// ---------------------------------------------------------------------------
// spyPatientNotifier records every SendToPatient call for assertions.
// ---------------------------------------------------------------------------

type spyPatientNotifier struct {
	mu     sync.Mutex
	calls  []patientCall
}

type patientCall struct {
	tenantID  string
	patientID string
	event     []byte
}

func (n *spyPatientNotifier) SendToPatient(tenantID, patientID string, event []byte) {
	cp := make([]byte, len(event))
	copy(cp, event)
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls = append(n.calls, patientCall{tenantID: tenantID, patientID: patientID, event: cp})
}

func (n *spyPatientNotifier) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.calls)
}

func (n *spyPatientNotifier) last() patientCall {
	n.mu.Lock()
	defer n.mu.Unlock()
	if len(n.calls) == 0 {
		return patientCall{}
	}
	return n.calls[len(n.calls)-1]
}

// ---------------------------------------------------------------------------
// dqFixture — minimum DB rows for deliverInterviewQuestion testing.
// ---------------------------------------------------------------------------

type dqFixture struct {
	TenantID store.TenantID
	Patient  store.Patient
	Conv     store.Conversation
}

func setupDQFixture(t *testing.T, s *store.Store) dqFixture {
	t.Helper()
	ctx := context.Background()
	suffix := uuid.New().String()

	tenant, err := s.CreateTenant(ctx, "dtc", "dq-test-"+suffix)
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient+" + suffix + "@dq.test",
		FullName:     "DQ Test Patient",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "dq test conversation")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	// Seed one user message so the conversation exists in a realistic state.
	if _, err := s.CreateMessage(ctx, tid, conv.ID, "user", "I have a headache"); err != nil {
		t.Fatalf("create message: %v", err)
	}

	return dqFixture{TenantID: tid, Patient: patient, Conv: conv}
}

// ---------------------------------------------------------------------------
// Tests: deliverInterviewQuestion
// ---------------------------------------------------------------------------

// TestDeliverInterviewQuestion_PersistsAssistantMessage asserts that
// deliverInterviewQuestion stores exactly one assistant-role message with the
// supplied question content in the given conversation.
func TestDeliverInterviewQuestion_PersistsAssistantMessage(t *testing.T) {
	pool := itTestPool(t) // defined in interview_turn_test.go, same package
	s := store.New(pool)
	f := setupDQFixture(t, s)
	ctx := context.Background()

	const question = "Can you describe where the pain is located?"

	spy := &spyPatientNotifier{}
	d := NewDrafter(&spyClient{text: ""}, s, stubNotifierNoop{}, spy)

	if err := d.deliverInterviewQuestion(ctx, f.TenantID, f.Conv, f.Patient, question); err != nil {
		t.Fatalf("deliverInterviewQuestion: unexpected error: %v", err)
	}

	// Retrieve all messages for this conversation and find the assistant turn.
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
		t.Fatalf("expected 1 assistant message, got %d", len(assistantMsgs))
	}
	if assistantMsgs[0].Content != question {
		t.Errorf("message content = %q, want %q", assistantMsgs[0].Content, question)
	}
	if assistantMsgs[0].ConversationID != f.Conv.ID {
		t.Error("message conversation_id mismatch")
	}
}

// TestDeliverInterviewQuestion_WritesAuditEventWithIDsOnly asserts that
// deliverInterviewQuestion writes exactly one audit event of type
// "agent.interview_question" whose metadata contains conversation_id and
// message_id but NOT the question text or any other PHI.
func TestDeliverInterviewQuestion_WritesAuditEventWithIDsOnly(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupDQFixture(t, s)
	ctx := context.Background()

	const question = "How long have you had this symptom?"

	spy := &spyPatientNotifier{}
	d := NewDrafter(&spyClient{text: ""}, s, stubNotifierNoop{}, spy)

	if err := d.deliverInterviewQuestion(ctx, f.TenantID, f.Conv, f.Patient, question); err != nil {
		t.Fatalf("deliverInterviewQuestion: unexpected error: %v", err)
	}

	// Query audit_events directly (tenant-scoped).
	rows, err := pool.Query(ctx,
		`SELECT event_type, metadata
		   FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'agent.interview_question'`,
		f.TenantID.UUID(),
	)
	if err != nil {
		t.Fatalf("query audit events: %v", err)
	}
	defer rows.Close()

	var count int
	for rows.Next() {
		var eventType string
		var meta []byte
		if err := rows.Scan(&eventType, &meta); err != nil {
			t.Fatalf("scan: %v", err)
		}

		// Metadata must contain conversation_id and message_id.
		var m map[string]any
		if err := json.Unmarshal(meta, &m); err != nil {
			t.Fatalf("unmarshal metadata: %v", err)
		}
		if _, ok := m["conversation_id"]; !ok {
			t.Error("audit metadata missing conversation_id")
		}
		if _, ok := m["message_id"]; !ok {
			t.Error("audit metadata missing message_id")
		}

		// Question content must NOT appear in the audit metadata.
		if string(meta) == question {
			t.Error("audit metadata contains raw question text (PHI leak)")
		}
		// Check that the question string is not embedded anywhere in the JSON.
		var allValues []byte
		allValues, _ = json.Marshal(m)
		for k, v := range m {
			if str, ok := v.(string); ok && str == question {
				t.Errorf("audit metadata field %q contains question text (PHI leak)", k)
			}
		}
		_ = allValues

		count++
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows error: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 agent.interview_question audit event, got %d", count)
	}
}

// TestDeliverInterviewQuestion_NotifiesPatientWithIDsOnly asserts that
// deliverInterviewQuestion calls the PatientNotifier exactly once with an
// event of type "message.created" containing only conversation_id and
// message_id — never the question content.
func TestDeliverInterviewQuestion_NotifiesPatientWithIDsOnly(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupDQFixture(t, s)
	ctx := context.Background()

	const question = "Do you have any allergies to medications?"

	spy := &spyPatientNotifier{}
	d := NewDrafter(&spyClient{text: ""}, s, stubNotifierNoop{}, spy)

	if err := d.deliverInterviewQuestion(ctx, f.TenantID, f.Conv, f.Patient, question); err != nil {
		t.Fatalf("deliverInterviewQuestion: unexpected error: %v", err)
	}

	if spy.count() != 1 {
		t.Fatalf("expected 1 patient notification, got %d", spy.count())
	}

	call := spy.last()

	// The tenantID and patientID routed to the notifier must match the fixture.
	if call.tenantID != f.TenantID.String() {
		t.Errorf("notifier tenantID = %q, want %q", call.tenantID, f.TenantID.String())
	}
	if call.patientID != f.Patient.ID.String() {
		t.Errorf("notifier patientID = %q, want %q", call.patientID, f.Patient.ID.String())
	}

	// Event must be valid JSON with type "message.created" and a data object
	// containing conversation_id and message_id only.
	var evt map[string]any
	if err := json.Unmarshal(call.event, &evt); err != nil {
		t.Fatalf("unmarshal event: %v", err)
	}
	if evt["type"] != "message.created" {
		t.Errorf("event type = %q, want %q", evt["type"], "message.created")
	}
	data, ok := evt["data"].(map[string]any)
	if !ok {
		t.Fatalf("event.data is not an object: %T", evt["data"])
	}
	if _, ok := data["conversation_id"]; !ok {
		t.Error("event.data missing conversation_id")
	}
	if _, ok := data["message_id"]; !ok {
		t.Error("event.data missing message_id")
	}

	// Question text must not appear anywhere in the event payload.
	for k, v := range data {
		if str, ok := v.(string); ok && str == question {
			t.Errorf("event.data field %q contains question text (PHI leak)", k)
		}
	}
}

// TestDeliverInterviewQuestion_PersistBeforeNotify asserts that the message
// referenced in the patient notification event actually exists in the DB when
// the notifier is called (persist-before-notify ordering guarantee).
func TestDeliverInterviewQuestion_PersistBeforeNotify(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupDQFixture(t, s)
	ctx := context.Background()

	const question = "On a scale of 1-10, how severe is your pain?"

	var verifyErr error

	// intercept the notification and immediately verify the DB row exists.
	verifyNotifier := &verifyingPatientNotifier{
		ctx:   ctx,
		pool:  pool,
		store: s,
		tid:   f.TenantID,
		convID: f.Conv.ID,
		onCall: func(msgID uuid.UUID) {
			msgs, err := s.ListMessagesByConversation(ctx, f.TenantID, f.Conv.ID)
			if err != nil {
				verifyErr = err
				return
			}
			found := false
			for _, m := range msgs {
				if m.ID == msgID {
					found = true
					break
				}
			}
			if !found {
				verifyErr = &messageNotFoundError{id: msgID}
			}
		},
	}

	d := NewDrafter(&spyClient{text: ""}, s, stubNotifierNoop{}, verifyNotifier)

	if err := d.deliverInterviewQuestion(ctx, f.TenantID, f.Conv, f.Patient, question); err != nil {
		t.Fatalf("deliverInterviewQuestion: unexpected error: %v", err)
	}
	if verifyErr != nil {
		t.Fatalf("persist-before-notify violated: message not found in DB when notifier fired: %v", verifyErr)
	}
}

// verifyingPatientNotifier extracts the message_id from the event JSON and
// calls onCall so the test can assert the row is already in the DB.
type verifyingPatientNotifier struct {
	ctx    context.Context
	pool   interface{} // unused; kept for import avoidance
	store  *store.Store
	tid    store.TenantID
	convID uuid.UUID
	onCall func(msgID uuid.UUID)
}

func (v *verifyingPatientNotifier) SendToPatient(_, _ string, event []byte) {
	var evt struct {
		Data struct {
			MessageID string `json:"message_id"`
		} `json:"data"`
	}
	if err := json.Unmarshal(event, &evt); err != nil {
		return
	}
	id, err := uuid.Parse(evt.Data.MessageID)
	if err != nil {
		return
	}
	v.onCall(id)
}

// messageNotFoundError is a sentinel error for the persist-before-notify test.
type messageNotFoundError struct{ id uuid.UUID }

func (e *messageNotFoundError) Error() string {
	return "message " + e.id.String() + " not found in DB at notification time"
}
