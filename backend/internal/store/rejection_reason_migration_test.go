package store

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/markolonius/housecall/backend/internal/domain"
)

// TestRecommendation_RejectionReasonColumn confirms migration
// 0005_recommendation_rejection_reason has been applied: the
// recommendations table has a nullable rejection_reason text column that
// defaults to NULL and round-trips an arbitrary string. The store-layer
// field and non-empty-on-rejection enforcement are added later alongside
// the Transition changes (see
// openspec/changes/add-agent-care-loop/specs/physician-in-loop/spec.md).
func TestRecommendation_RejectionReasonColumn(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tid := TenantID(f.A.Tenant.ID)

	rec, err := s.CreateRecommendation(ctx, tid, Recommendation{
		ConversationID: f.A.Conversation.ID,
		PatientID:      f.A.Patient.ID,
		State:          domain.StateDraft,
		PayloadType:    "guidance",
		Payload:        json.RawMessage(`{"text":"x"}`),
		DraftContent:   "draft",
	})
	if err != nil {
		t.Fatalf("create recommendation: %v", err)
	}

	var reason *string
	if err := pool.QueryRow(ctx,
		`SELECT rejection_reason FROM recommendations WHERE tenant_id = $1 AND id = $2`,
		tid, rec.ID,
	).Scan(&reason); err != nil {
		t.Fatalf("query rejection_reason: %v", err)
	}
	if reason != nil {
		t.Errorf("rejection_reason = %q, want NULL by default", *reason)
	}

	const want = "ask about current medications"
	if _, err := pool.Exec(ctx,
		`UPDATE recommendations SET rejection_reason = $1 WHERE tenant_id = $2 AND id = $3`,
		want, tid, rec.ID,
	); err != nil {
		t.Fatalf("set rejection_reason: %v", err)
	}
	if err := pool.QueryRow(ctx,
		`SELECT rejection_reason FROM recommendations WHERE tenant_id = $1 AND id = $2`,
		tid, rec.ID,
	).Scan(&reason); err != nil {
		t.Fatalf("query rejection_reason after update: %v", err)
	}
	if reason == nil || *reason != want {
		t.Errorf("rejection_reason = %v, want %q", reason, want)
	}
}
