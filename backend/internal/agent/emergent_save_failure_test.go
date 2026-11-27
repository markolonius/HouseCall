package agent

import (
	"context"
	"testing"

	"github.com/google/uuid"

	"github.com/markolonius/housecall/backend/internal/store"
)

// TestRunEmergentTurn_SaveFailure_StillNotifiesPhysicianAndAudits forces the
// referral message insert to fail (the conversation does not exist, so the FK
// rejects it) and verifies the urgent physician notification and audit event
// still happen, the error is returned, and the patient is not pointed at a
// message that does not exist.
func TestRunEmergentTurn_SaveFailure_StillNotifiesPhysicianAndAudits(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)
	f := setupIntegrationFixture(t, s)
	ctx := context.Background()

	ghost := f.Conv
	ghost.ID = uuid.New()

	phys := &captureNotifier{}
	pat := &spyPatientNotifier{}
	d := NewDrafter(&sequentialClient{}, s, phys, pat)

	if err := d.runEmergentTurn(ctx, f.TenantID, ghost, f.Patient); err == nil {
		t.Fatal("want the save error returned, got nil")
	}
	if phys.count() != 1 {
		t.Errorf("urgent physician notifications = %d, want 1", phys.count())
	}
	if pat.count() != 0 {
		t.Errorf("patient notifications = %d, want 0 (no message exists)", pat.count())
	}

	var n int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'agent.emergent_triage'
		    AND metadata->>'conversation_id' = $2
		    AND metadata->>'message_id' IS NULL`,
		f.TenantID.UUID(), ghost.ID.String(),
	).Scan(&n); err != nil {
		t.Fatalf("query audit: %v", err)
	}
	if n != 1 {
		t.Errorf("emergent_triage audit rows = %d, want 1", n)
	}
}
