package store

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/markolonius/housecall/backend/internal/domain"
)

// TestCreateRecommendation_SOAPNote verifies that the database accepts a
// soap_note recommendation with a valid four-section payload (i.e. the
// migration 0003_soap_note_payload has been applied and the CHECK constraint
// now includes 'soap_note').
func TestCreateRecommendation_SOAPNote(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tid := TenantID(f.A.Tenant.ID)

	soapPayload := domain.SOAPPayload{
		Subjective: "patient reports headache for 3 days, worse in the morning",
		Objective:  "none reported (text interview only)",
		Assessment: "tension-type headache",
		Plan:       "recommend rest, hydration, and OTC ibuprofen; follow up if no improvement in 48 h",
	}
	raw, err := json.Marshal(soapPayload)
	if err != nil {
		t.Fatalf("marshal soap payload: %v", err)
	}

	// Validate the payload before persisting (mirrors what the drafter will do).
	if err := domain.ValidateSOAPPayload(raw); err != nil {
		t.Fatalf("soap payload failed domain validation: %v", err)
	}

	rec, err := s.CreateRecommendation(ctx, tid, Recommendation{
		ConversationID: f.A.Conversation.ID,
		PatientID:      f.A.Patient.ID,
		State:          domain.StateDraft,
		PayloadType:    domain.PayloadTypeSOAPNote,
		Payload:        raw,
		DraftContent:   "Headache note draft",
	})
	if err != nil {
		t.Fatalf("create soap_note recommendation: %v", err)
	}

	if rec.PayloadType != domain.PayloadTypeSOAPNote {
		t.Errorf("payload_type = %q, want %q", rec.PayloadType, domain.PayloadTypeSOAPNote)
	}
	if rec.State != domain.StateDraft {
		t.Errorf("state = %q, want %q", rec.State, domain.StateDraft)
	}
	if rec.TenantID != tid {
		t.Errorf("tenant_id mismatch: got %v, want %v", rec.TenantID, tid)
	}

	// Round-trip: fetch and confirm all four sections survive.
	fetched, err := s.GetRecommendation(ctx, tid, rec.ID)
	if err != nil {
		t.Fatalf("get recommendation: %v", err)
	}
	var roundTripped domain.SOAPPayload
	if err := json.Unmarshal(fetched.Payload, &roundTripped); err != nil {
		t.Fatalf("unmarshal round-tripped payload: %v", err)
	}
	if roundTripped.Subjective != soapPayload.Subjective {
		t.Errorf("Subjective mismatch: got %q, want %q", roundTripped.Subjective, soapPayload.Subjective)
	}
	if roundTripped.Objective != soapPayload.Objective {
		t.Errorf("Objective mismatch: got %q, want %q", roundTripped.Objective, soapPayload.Objective)
	}
	if roundTripped.Assessment != soapPayload.Assessment {
		t.Errorf("Assessment mismatch: got %q, want %q", roundTripped.Assessment, soapPayload.Assessment)
	}
	if roundTripped.Plan != soapPayload.Plan {
		t.Errorf("Plan mismatch: got %q, want %q", roundTripped.Plan, soapPayload.Plan)
	}
}

// TestCreateRecommendation_SOAPNote_SchemaRejectsInvalidPayloadType confirms
// that the Postgres CHECK constraint still rejects an unknown payload_type
// string after the migration (regression guard).
func TestCreateRecommendation_SOAPNote_SchemaRejectsInvalidPayloadType(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tid := TenantID(f.A.Tenant.ID)

	_, err := s.CreateRecommendation(ctx, tid, Recommendation{
		ConversationID: f.A.Conversation.ID,
		PatientID:      f.A.Patient.ID,
		State:          domain.StateDraft,
		PayloadType:    "unknown_type",
		Payload:        []byte(`{}`),
		DraftContent:   "should fail",
	})
	if err == nil {
		t.Fatal("expected schema CHECK violation for unknown payload_type, got nil error")
	}
}
