package agent

import (
	"context"
	"testing"

	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/store"
)

// --- normalizeHeaderLine / parseSOAPSections: tolerate Markdown-decorated headers ---

func TestNormalizeHeaderLine(t *testing.T) {
	cases := map[string]string{
		"SUBJECTIVE:":      "SUBJECTIVE:",
		"  subjective:  ":  "SUBJECTIVE:",
		"**SUBJECTIVE:**":  "SUBJECTIVE:",
		"### Objective":    "OBJECTIVE",
		"1. ASSESSMENT":    "ASSESSMENT",
		"2) Plan":          "PLAN",
		"- PLAN:":          "PLAN:",
		"__Assessment:__":  "ASSESSMENT:",
		"> SUBJECTIVE":     "SUBJECTIVE",
	}
	for in, want := range cases {
		if got := normalizeHeaderLine(in); got != want {
			t.Errorf("normalizeHeaderLine(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestParseSOAPSections_DecoratedHeaders(t *testing.T) {
	raw := `Here is the note:

**SUBJECTIVE:**
34yo male, sore throat and fever x2 days.

### Objective
None reported

1. ASSESSMENT
Preliminary assessment: likely viral pharyngitis; requires physician review.

- PLAN:
Rest, fluids, paracetamol; seek care if worsening.`
	sp, err := parseSOAPSections(raw)
	if err != nil {
		t.Fatalf("parseSOAPSections on decorated headers: %v", err)
	}
	if err := sp.Validate(); err != nil {
		t.Fatalf("validate: %v", err)
	}
	for name, v := range map[string]string{"subjective": sp.Subjective, "objective": sp.Objective, "assessment": sp.Assessment, "plan": sp.Plan} {
		if v == "" {
			t.Errorf("section %q is empty", name)
		}
	}
}

// --- draftSOAPNote retry on parse failure ---

func TestDraftSOAPNote_RetriesOnParseError(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupSOAPDrafterFixture(t, s)
	ctx := context.Background()
	notifier := &captureNotifier{}

	// First generation is malformed (no headers); second is well-formed.
	client := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: "I'm not sure how to format this note.", err: nil},
		{text: wellFormedSOAPText, err: nil},
	}}
	d := NewDrafter(client, s, notifier, notifier)

	if err := d.draftSOAPNote(ctx, f.TenantID, f.Conv, f.Patient); err != nil {
		t.Fatalf("draftSOAPNote should succeed on retry, got: %v", err)
	}
	// Both responses consumed → it retried after the first parse failure.
	if client.idx != 2 {
		t.Errorf("expected 2 model calls (retry), got %d", client.idx)
	}
	recs, _ := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	n := 0
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID && r.PayloadType == domain.PayloadTypeSOAPNote {
			n++
		}
	}
	if n != 1 {
		t.Errorf("expected 1 PENDING_REVIEW soap_note after retry, got %d", n)
	}
}

func TestDraftSOAPNote_DoesNotRetryOnModelError(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupSOAPDrafterFixture(t, s)
	ctx := context.Background()
	notifier := &captureNotifier{}

	// A transport/model error must surface immediately — no retry (a model
	// outage must not be masked by burning all attempts).
	client := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: "", err: &ModelError{StatusCode: 500}},
		{text: wellFormedSOAPText, err: nil}, // must NOT be reached
	}}
	d := NewDrafter(client, s, notifier, notifier)

	if err := d.draftSOAPNote(ctx, f.TenantID, f.Conv, f.Patient); err == nil {
		t.Fatal("draftSOAPNote should return the model error")
	}
	if client.idx != 1 {
		t.Errorf("model error must not be retried; expected 1 call, got %d", client.idx)
	}
}

func TestDraftSOAPNote_FailsAfterMaxAttempts(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupSOAPDrafterFixture(t, s)
	ctx := context.Background()
	notifier := &captureNotifier{}

	// Every generation malformed → exhausts soapDraftMaxAttempts, no row persisted.
	client := &sequentialClient{responses: []struct {
		text string
		err  error
	}{
		{text: "no headers here", err: nil},
		{text: "still no headers", err: nil},
		{text: "nope", err: nil},
		{text: "extra (should not be reached)", err: nil},
	}}
	d := NewDrafter(client, s, notifier, notifier)

	if err := d.draftSOAPNote(ctx, f.TenantID, f.Conv, f.Patient); err == nil {
		t.Fatal("draftSOAPNote should fail after max attempts on persistently malformed output")
	}
	if client.idx != soapDraftMaxAttempts {
		t.Errorf("expected %d model calls, got %d", soapDraftMaxAttempts, client.idx)
	}
	recs, _ := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			t.Fatal("no recommendation must be persisted when all attempts fail")
		}
	}
}
