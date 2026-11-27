package agent

// The interview turn cap counts only the questions of the CURRENT interview
// (since the conversation last entered INTAKE), so a re-interview after a
// capped first interview is not skipped.

import (
	"context"
	"testing"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/review"
	"github.com/markolonius/housecall/backend/internal/store"
)

type scripted = []struct {
	text string
	err  error
}

// capFirstInterview seeds DefaultMaxInterviewTurns assistant questions, then
// runs a turn that forces the cap-triggered SOAP draft (AWAITING_REVIEW) and
// returns the resulting PENDING_REVIEW recommendation.
func capFirstInterview(t *testing.T, s *store.Store, f integrationFixture) store.Recommendation {
	t.Helper()
	ctx := context.Background()
	for i := 0; i < DefaultMaxInterviewTurns; i++ {
		if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "assistant", "question"); err != nil {
			t.Fatalf("seed question: %v", err)
		}
	}
	d := NewDrafter(&sequentialClient{responses: scripted{
		{text: "yet another question"}, // no marker; cap forces the draft
		{text: wellFormedSOAPText},
	}}, s, &captureNotifier{}, &spyPatientNotifier{})
	if err := d.runInterviewTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("first interview capped turn: %v", err)
	}
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list pending: %v", err)
	}
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			return r
		}
	}
	t.Fatal("capped first interview did not draft a recommendation")
	return store.Recommendation{}
}

func lastAssistantContent(t *testing.T, s *store.Store, f integrationFixture) string {
	t.Helper()
	msgs, err := s.ListMessagesByConversation(context.Background(), f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	for i := len(msgs) - 1; i >= 0; i-- {
		if msgs[i].Role == "assistant" {
			return msgs[i].Content
		}
	}
	return ""
}

func TestInterviewCap_RejectionReInterviewAsksQuestion(t *testing.T) {
	s := store.New(itTestPool(t))
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	rec := capFirstInterview(t, s, f)
	if _, err := review.Execute(ctx, s, f.TenantID, f.Physician.ID, rec.ID, domain.ActionReject, "", "ask about medications"); err != nil {
		t.Fatalf("reject: %v", err)
	}
	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "ok"); err != nil {
		t.Fatalf("user message: %v", err)
	}

	const q = "Which medications are you taking?"
	d := NewDrafter(&sequentialClient{responses: scripted{{text: q}}}, s, &captureNotifier{}, &spyPatientNotifier{})
	if err := d.runInterviewTurn(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("re-interview turn: %v", err)
	}
	if got := lastAssistantContent(t, s, f); got != q {
		t.Errorf("re-interview should ask a question, last assistant message = %q", got)
	}
}

func TestInterviewCap_NewComplaintInterviewAsksQuestion(t *testing.T) {
	s := store.New(itTestPool(t))
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	rec := capFirstInterview(t, s, f)
	if _, err := review.Execute(ctx, s, f.TenantID, f.Physician.ID, rec.ID, domain.ActionApprove, "", ""); err != nil {
		t.Fatalf("approve: %v", err)
	}
	if _, err := s.CreateMessage(ctx, f.TenantID, f.Conv.ID, "user", "I also have a new rash"); err != nil {
		t.Fatalf("user message: %v", err)
	}
	conv, err := s.GetConversation(ctx, f.TenantID, f.Conv.ID)
	if err != nil {
		t.Fatalf("get conversation: %v", err)
	}

	const q = "What does the rash look like?"
	d := NewDrafter(&triageSequentialClient{responses: scripted{
		{text: NewComplaintMarker},
		{text: RoutineMarker},
		{text: q},
	}}, s, &captureNotifier{}, &spyPatientNotifier{})
	if err := d.runPlanDeliveredTurn(ctx, f.TenantID, conv, f.Patient); err != nil {
		t.Fatalf("new-complaint turn: %v", err)
	}
	if got := lastAssistantContent(t, s, f); got != q {
		t.Errorf("new-complaint interview should ask a question, last assistant message = %q", got)
	}
}
