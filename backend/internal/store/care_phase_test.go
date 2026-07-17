package store

import (
	"context"
	"errors"
	"testing"

	"github.com/google/uuid"
)

// seedCarePhaseConversation creates a tenant, patient, and conversation, then
// (if phase != CarePhaseIntake, the DB default) fast-forwards the row to
// `phase` via a direct SQL write. This is test setup only — it deliberately
// bypasses TransitionCarePhase so each test below exercises the helper
// against a known starting state without depending on it for setup.
func seedCarePhaseConversation(t *testing.T, s *Store, phase CarePhase) (TenantID, Conversation) {
	t.Helper()
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "care-phase-test-"+uuid.NewString())
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, Patient{
		Email:        "patient@" + uuid.NewString() + ".test",
		FullName:     "Care Phase Patient",
		State:        "PA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "care phase test")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	if conv.CarePhase != CarePhaseIntake {
		t.Fatalf("new conversation care_phase = %q, want %q (DB default)", conv.CarePhase, CarePhaseIntake)
	}

	if phase != CarePhaseIntake {
		if _, err := s.pool.Exec(ctx,
			`UPDATE conversations SET care_phase = $3 WHERE tenant_id = $1 AND id = $2`,
			tid.UUID(), conv.ID, string(phase),
		); err != nil {
			t.Fatalf("seed care_phase=%s: %v", phase, err)
		}
		conv.CarePhase = phase
	}

	return tid, conv
}

// TestConversationCRUD_CarePhase verifies CreateConversation, GetConversation,
// and ListConversationsByPatient all read/write care_phase.
func TestConversationCRUD_CarePhase(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tenant, err := s.CreateTenant(ctx, "dtc", "care-phase-crud")
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, Patient{
		Email:        "patient@crud.test",
		FullName:     "CRUD Patient",
		State:        "PA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	created, err := s.CreateConversation(ctx, tid, patient.ID, "first visit")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}
	if created.CarePhase != CarePhaseIntake {
		t.Fatalf("CreateConversation care_phase = %q, want INTAKE", created.CarePhase)
	}

	fetched, err := s.GetConversation(ctx, tid, created.ID)
	if err != nil {
		t.Fatalf("get conversation: %v", err)
	}
	if fetched.CarePhase != CarePhaseIntake {
		t.Fatalf("GetConversation care_phase = %q, want INTAKE", fetched.CarePhase)
	}

	// Move the row out of the DB default so List is also asserting a
	// non-default value round-trips correctly, not just the zero value.
	if _, err := pool.Exec(ctx,
		`UPDATE conversations SET care_phase = $3 WHERE tenant_id = $1 AND id = $2`,
		tid.UUID(), created.ID, string(CarePhaseAwaitingReview),
	); err != nil {
		t.Fatalf("seed care_phase: %v", err)
	}

	list, err := s.ListConversationsByPatient(ctx, tid, patient.ID)
	if err != nil {
		t.Fatalf("list conversations: %v", err)
	}
	if len(list) != 1 || list[0].CarePhase != CarePhaseAwaitingReview {
		t.Fatalf("ListConversationsByPatient = %+v, want single AWAITING_REVIEW row", list)
	}
}

// TestTransitionCarePhase_AllowedEdges exercises every edge the state
// machine permits and asserts the row lands on `to` after commit.
func TestTransitionCarePhase_AllowedEdges(t *testing.T) {
	cases := []struct {
		name string
		from CarePhase
		to   CarePhase
	}{
		{"intake to awaiting review", CarePhaseIntake, CarePhaseAwaitingReview},
		{"awaiting review to plan delivered", CarePhaseAwaitingReview, CarePhasePlanDelivered},
		{"awaiting review to intake (rejection)", CarePhaseAwaitingReview, CarePhaseIntake},
		{"plan delivered to intake (new complaint)", CarePhasePlanDelivered, CarePhaseIntake},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			pool := testPool(t)
			s := New(pool)
			ctx := context.Background()

			tid, conv := seedCarePhaseConversation(t, s, tc.from)

			err := s.Txn(ctx, func(tx *TxStore) error {
				return tx.TransitionCarePhase(ctx, tid, conv.ID, tc.from, tc.to)
			})
			if err != nil {
				t.Fatalf("TransitionCarePhase(%s -> %s) = %v, want nil", tc.from, tc.to, err)
			}

			got, err := s.GetConversation(ctx, tid, conv.ID)
			if err != nil {
				t.Fatalf("get conversation: %v", err)
			}
			if got.CarePhase != tc.to {
				t.Fatalf("care_phase after transition = %q, want %q", got.CarePhase, tc.to)
			}
		})
	}
}

// TestTransitionCarePhase_DisallowedEdges exercises every (from, to) pair
// that is NOT one of the four allowed edges — including same-state no-ops —
// and asserts ErrInvalidCarePhaseTransition is returned and the row is left
// unchanged.
func TestTransitionCarePhase_DisallowedEdges(t *testing.T) {
	allPhases := []CarePhase{CarePhaseIntake, CarePhaseAwaitingReview, CarePhasePlanDelivered}
	allowed := map[CarePhase]map[CarePhase]bool{
		CarePhaseIntake:         {CarePhaseAwaitingReview: true},
		CarePhaseAwaitingReview: {CarePhasePlanDelivered: true, CarePhaseIntake: true},
		CarePhasePlanDelivered:  {CarePhaseIntake: true},
	}

	var cases []struct {
		from CarePhase
		to   CarePhase
	}
	for _, from := range allPhases {
		for _, to := range allPhases {
			if allowed[from][to] {
				continue
			}
			cases = append(cases, struct {
				from CarePhase
				to   CarePhase
			}{from, to})
		}
	}

	// Sanity: 3x3 grid minus 4 allowed edges leaves 5 disallowed pairs,
	// including all 3 same-state no-ops.
	if len(cases) != 5 {
		t.Fatalf("expected 5 disallowed edges, got %d: %+v", len(cases), cases)
	}

	for _, tc := range cases {
		t.Run(string(tc.from)+"_to_"+string(tc.to), func(t *testing.T) {
			pool := testPool(t)
			s := New(pool)
			ctx := context.Background()

			tid, conv := seedCarePhaseConversation(t, s, tc.from)

			err := s.Txn(ctx, func(tx *TxStore) error {
				return tx.TransitionCarePhase(ctx, tid, conv.ID, tc.from, tc.to)
			})
			if !errors.Is(err, ErrInvalidCarePhaseTransition) {
				t.Fatalf("TransitionCarePhase(%s -> %s) = %v, want ErrInvalidCarePhaseTransition", tc.from, tc.to, err)
			}

			got, err := s.GetConversation(ctx, tid, conv.ID)
			if err != nil {
				t.Fatalf("get conversation: %v", err)
			}
			if got.CarePhase != tc.from {
				t.Fatalf("care_phase after disallowed transition = %q, want unchanged %q", got.CarePhase, tc.from)
			}
		})
	}
}

// TestTransitionCarePhase_TenantIsolation verifies that calling
// TransitionCarePhase with a tenant id that does not own the conversation
// neither transitions the row nor leaks its existence: it returns
// ErrNotFound and the row's phase (readable under the correct tenant) is
// unchanged.
func TestTransitionCarePhase_TenantIsolation(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	ctx := context.Background()

	tidA, convA := seedCarePhaseConversation(t, s, CarePhaseAwaitingReview)

	otherTenant, err := s.CreateTenant(ctx, "dtc", "care-phase-tenant-b")
	if err != nil {
		t.Fatalf("create tenant B: %v", err)
	}
	tidB := TenantID(otherTenant.ID)

	err = s.Txn(ctx, func(tx *TxStore) error {
		return tx.TransitionCarePhase(ctx, tidB, convA.ID, CarePhaseAwaitingReview, CarePhasePlanDelivered)
	})
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-tenant TransitionCarePhase = %v, want ErrNotFound", err)
	}

	got, err := s.GetConversation(ctx, tidA, convA.ID)
	if err != nil {
		t.Fatalf("get conversation under owning tenant: %v", err)
	}
	if got.CarePhase != CarePhaseAwaitingReview {
		t.Fatalf("care_phase after cross-tenant attempt = %q, want unchanged AWAITING_REVIEW", got.CarePhase)
	}
}
