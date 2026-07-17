// Package agent — internal test file for task 3.3: INTAKE interview turns
// include the latest rejection reason as reviewer guidance in the model
// context, and that reason is never written to any patient-facing message.
//
// Uses "package agent" (see interview_turn_test.go) to reach the unexported
// generateInterviewTurn and rejectionGuidanceMessage helpers, and reuses the
// itTestPool/itSetupConversation/spyClient/stubNotifierNoop fixtures defined
// there.
package agent

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// itSetReviewed creates a recommendation in the given state for f's
// conversation/patient and, via a raw UPDATE, stamps reviewed_at and
// rejection_reason directly. Production code only ever sets these through
// store.TxWriter.UpdateRecommendationRejection/UpdateRecommendationState;
// driving them directly here lets the test control ordering between rows
// precisely (see store.GetLatestRejectionReason's "newer than any delivered
// recommendation" rule).
func itSetReviewed(t *testing.T, s *store.Store, f itFixture, state string, reason *string, reviewedAt time.Time) store.Recommendation {
	t.Helper()
	ctx := context.Background()

	rec, err := s.CreateRecommendation(ctx, f.TenantID, store.Recommendation{
		ConversationID: f.Conv.ID,
		PatientID:      f.Conv.PatientID,
		State:          state,
		PayloadType:    "guidance",
		Payload:        json.RawMessage(`{"text":"x"}`),
		DraftContent:   "draft",
	})
	if err != nil {
		t.Fatalf("create recommendation: %v", err)
	}

	if _, err := s.Pool().Exec(ctx,
		`UPDATE recommendations SET reviewed_at = $3, rejection_reason = $4
		  WHERE tenant_id = $1 AND id = $2`,
		f.TenantID.UUID(), rec.ID, reviewedAt, reason,
	); err != nil {
		t.Fatalf("stamp reviewed_at/rejection_reason: %v", err)
	}
	return rec
}

// TestGenerateInterviewTurn_RejectionReasonInjected verifies that when the
// conversation's latest reviewed outcome is a REJECTED recommendation, an
// additional system-role message carrying the reason is inserted between
// InterviewSystemPrompt and the conversation history — never as the leading
// system message (InterviewSystemPrompt stays static/shared), and never
// substituted into a user/assistant turn.
func TestGenerateInterviewTurn_RejectionReasonInjected(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	f := itSetupConversation(t, s, []struct{ Role, Content string }{
		{"user", "My headache is back."},
	})

	const reason = "ask about current medications"
	itSetReviewed(t, s, f, domain.StateRejected, strPtr(reason), time.Now())

	spy := &spyClient{text: "Are you currently taking any medications?"}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	_, err := d.generateInterviewTurn(context.Background(), f.TenantID, f.Conv)
	if err != nil {
		t.Fatalf("generateInterviewTurn: unexpected error: %v", err)
	}

	if len(spy.captured) != 1 {
		t.Fatalf("expected exactly 1 Complete call, got %d", len(spy.captured))
	}
	got := spy.captured[0]

	// Expect: [system: InterviewSystemPrompt, system: guidance, user: history...]
	if len(got) < 2 {
		t.Fatalf("expected at least 2 messages before history, got %d", len(got))
	}
	if got[0].Content != InterviewSystemPrompt {
		t.Errorf("got[0] is not InterviewSystemPrompt; leading system message must stay static")
	}
	if got[1].Role != "system" {
		t.Errorf("got[1].Role = %q, want %q (rejection guidance message)", got[1].Role, "system")
	}
	if !strings.Contains(got[1].Content, reason) {
		t.Errorf("got[1].Content does not contain the rejection reason: %q", got[1].Content)
	}
	if got[1].Content == InterviewSystemPrompt {
		t.Error("rejection guidance must not be folded into InterviewSystemPrompt (shared/static prompt)")
	}

	// The reason must not leak into the conversation-history messages.
	for i, m := range got[2:] {
		if strings.Contains(m.Content, reason) {
			t.Errorf("history message %d unexpectedly contains the rejection reason", i)
		}
	}
}

// TestGenerateInterviewTurn_NoRejection_NoGuidanceMessage verifies that a
// conversation with no rejected recommendation gets the same two-message
// shape as before this task (system prompt + history only, no guidance
// message) — the existing interview-flow tests' assumptions stay valid.
func TestGenerateInterviewTurn_NoRejection_NoGuidanceMessage(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	f := itSetupConversation(t, s, []struct{ Role, Content string }{
		{"user", "I have a sore throat."},
	})

	spy := &spyClient{text: "How long have you had it?"}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	_, err := d.generateInterviewTurn(context.Background(), f.TenantID, f.Conv)
	if err != nil {
		t.Fatalf("generateInterviewTurn: unexpected error: %v", err)
	}

	got := spy.captured[0]
	// system prompt + 1 history message == 2; no guidance message inserted.
	if len(got) != 2 {
		t.Fatalf("message count = %d, want 2 (no rejection present)", len(got))
	}
	if got[1].Role != "user" {
		t.Errorf("got[1].Role = %q, want %q — guidance message must be absent", got[1].Role, "user")
	}
}

// TestGenerateInterviewTurn_StaleRejection_NoGuidanceMessage verifies that a
// rejection followed by a LATER delivery (plan subsequently approved/
// modified and delivered) does not surface guidance — the rejection is
// stale/irrelevant once a later plan has reached the patient.
func TestGenerateInterviewTurn_StaleRejection_NoGuidanceMessage(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	f := itSetupConversation(t, s, []struct{ Role, Content string }{
		{"user", "Different complaint now."},
	})

	older := time.Now().Add(-time.Hour)
	newer := time.Now()

	staleReason := "ask about current medications"
	itSetReviewed(t, s, f, domain.StateRejected, strPtr(staleReason), older)
	itSetReviewed(t, s, f, domain.StateDelivered, nil, newer)

	spy := &spyClient{text: "What's going on today?"}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	_, err := d.generateInterviewTurn(context.Background(), f.TenantID, f.Conv)
	if err != nil {
		t.Fatalf("generateInterviewTurn: unexpected error: %v", err)
	}

	got := spy.captured[0]
	for i, m := range got {
		if strings.Contains(m.Content, staleReason) {
			t.Errorf("message %d contains the stale rejection reason; want it absent after a later delivery", i)
		}
	}
	if len(got) != 2 {
		t.Fatalf("message count = %d, want 2 (stale rejection must not add a guidance message)", len(got))
	}
}

// TestRunInterviewTurn_RejectionReasonNeverPersistedToPatientMessage is an
// end-to-end check (through runInterviewTurn, the caller that actually
// writes patient-facing messages via deliverInterviewQuestion) that the
// rejection reason never ends up in a store.CreateMessage call: the only
// text ever persisted is the model's returned text, and the model here is a
// stub whose fixed output does not include the reason. This exercises the
// exact code path (runInterviewTurn -> generateInterviewTurn ->
// deliverInterviewQuestion -> store.CreateMessage) rather than only the
// context-assembly step.
func TestRunInterviewTurn_RejectionReasonNeverPersistedToPatientMessage(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	f := itSetupConversation(t, s, []struct{ Role, Content string }{
		{"user", "My headache is back."},
	})

	const reason = "ask about current medications — patient has a history of migraines"
	itSetReviewed(t, s, f, domain.StateRejected, strPtr(reason), time.Now())

	const modelQuestion = "Are you currently taking any medications for your headaches?"
	spy := &spyClient{text: modelQuestion}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	patient, err := s.GetPatient(context.Background(), f.TenantID, f.Conv.PatientID)
	if err != nil {
		t.Fatalf("get patient: %v", err)
	}

	if err := d.runInterviewTurn(context.Background(), f.TenantID, f.Conv, patient); err != nil {
		t.Fatalf("runInterviewTurn: unexpected error: %v", err)
	}

	// The model DID receive the reason as guidance (proves the wiring works)...
	found := false
	for _, m := range spy.captured[0] {
		if strings.Contains(m.Content, reason) {
			found = true
		}
	}
	if !found {
		t.Fatal("expected the model context to contain the rejection reason")
	}

	// ...but nothing persisted to the conversation contains it. This is the
	// only text deliverInterviewQuestion could have stored: the model's
	// returned question text.
	msgs, err := s.ListMessagesByConversation(context.Background(), f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(msgs) == 0 {
		t.Fatal("expected at least one persisted message")
	}
	for _, m := range msgs {
		if strings.Contains(m.Content, reason) {
			t.Errorf("persisted message (role=%s) contains the rejection reason verbatim", m.Role)
		}
	}
	// Sanity: the persisted assistant message is exactly the stub's output.
	last := msgs[len(msgs)-1]
	if last.Role != "assistant" || last.Content != modelQuestion {
		t.Errorf("last message = {role=%s, content=%q}, want {role=assistant, content=%q}",
			last.Role, last.Content, modelQuestion)
	}
}

func strPtr(s string) *string { return &s }
