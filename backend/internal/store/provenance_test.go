package store

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/markolonius/housecall/backend/internal/domain"
)

// TestRecommendation_ProvenanceRoundTrip checks model_name / prompt_version
// persist through create and read, and are NULL when not supplied.
func TestRecommendation_ProvenanceRoundTrip(t *testing.T) {
	s := New(testPool(t))
	f := setupFixture(t, s)
	ctx := context.Background()
	tid := TenantID(f.A.Tenant.ID)

	model, ver := "medgemma", "soap-draft/2026-11-27"
	mk := func(m, v *string) Recommendation {
		rec, err := s.CreateRecommendation(ctx, tid, Recommendation{
			ConversationID: f.A.Conversation.ID,
			PatientID:      f.A.Patient.ID,
			State:          domain.StateDraft,
			PayloadType:    "guidance",
			Payload:        json.RawMessage(`{"text":"x"}`),
			DraftContent:   "draft",
			ModelName:      m,
			PromptVersion:  v,
		})
		if err != nil {
			t.Fatalf("create: %v", err)
		}
		return rec
	}

	with := mk(&model, &ver)
	if with.ModelName == nil || *with.ModelName != model || with.PromptVersion == nil || *with.PromptVersion != ver {
		t.Fatalf("create returned wrong provenance: %+v %+v", with.ModelName, with.PromptVersion)
	}
	got, err := s.GetRecommendation(ctx, tid, with.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.ModelName == nil || *got.ModelName != model || got.PromptVersion == nil || *got.PromptVersion != ver {
		t.Fatalf("get returned wrong provenance: %+v %+v", got.ModelName, got.PromptVersion)
	}

	none := mk(nil, nil)
	got, err = s.GetRecommendation(ctx, tid, none.ID)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if got.ModelName != nil || got.PromptVersion != nil {
		t.Fatalf("expected NULL provenance, got %+v %+v", got.ModelName, got.PromptVersion)
	}
}
