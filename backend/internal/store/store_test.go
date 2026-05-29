package store

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
)

// fixture creates two tenants with a parallel set of patients,
// physicians, care relationships, conversations, messages, and
// recommendations so that tenant-isolation assertions can verify
// no query from tenant A returns tenant B's rows (and vice versa).
type fixture struct {
	A tenantFixture
	B tenantFixture
}

type tenantFixture struct {
	Tenant         Tenant
	Patient        Patient
	Physician      Physician
	Conversation   Conversation
	Message        Message
	Recommendation Recommendation
}

func setupFixture(t *testing.T, s *Store) fixture {
	t.Helper()
	ctx := context.Background()

	mk := func(name string) tenantFixture {
		tenant, err := s.CreateTenant(ctx, "dtc", name)
		if err != nil {
			t.Fatalf("create tenant: %v", err)
		}
		tid := TenantID(tenant.ID)

		patient, err := s.CreatePatient(ctx, tid, Patient{
			Email:        "patient@" + name + ".test",
			FullName:     "Patient " + name,
			State:        "PA",
			PasswordHash: "hash",
		})
		if err != nil {
			t.Fatalf("create patient: %v", err)
		}

		physician, err := s.CreatePhysician(ctx, tid, Physician{
			Email:          "doc@" + name + ".test",
			FullName:       "Doc " + name,
			StatesLicensed: []string{"PA"},
			PasswordHash:   "hash",
		})
		if err != nil {
			t.Fatalf("create physician: %v", err)
		}

		if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, physician.ID); err != nil {
			t.Fatalf("create care relationship: %v", err)
		}

		conv, err := s.CreateConversation(ctx, tid, patient.ID, "initial visit")
		if err != nil {
			t.Fatalf("create conversation: %v", err)
		}

		msg, err := s.CreateMessage(ctx, tid, conv.ID, "user", "hello "+name)
		if err != nil {
			t.Fatalf("create message: %v", err)
		}

		rec, err := s.CreateRecommendation(ctx, tid, Recommendation{
			ConversationID: conv.ID,
			PatientID:      patient.ID,
			State:          "PENDING_REVIEW",
			PayloadType:    "guidance",
			Payload:        json.RawMessage(`{"text":"draft for ` + name + `"}`),
			DraftContent:   "draft for " + name,
		})
		if err != nil {
			t.Fatalf("create recommendation: %v", err)
		}

		return tenantFixture{
			Tenant:         tenant,
			Patient:        patient,
			Physician:      physician,
			Conversation:   conv,
			Message:        msg,
			Recommendation: rec,
		}
	}

	return fixture{A: mk("a"), B: mk("b")}
}

func TestTenantIsolation_Patient(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)
	tidB := TenantID(f.B.Tenant.ID)

	// A's tenant id cannot fetch B's patient by id.
	if _, err := s.GetPatient(ctx, tidA, f.B.Patient.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("tenant A reading tenant B's patient: got %v, want ErrNotFound", err)
	}

	// B's tenant id cannot fetch A's patient by id.
	if _, err := s.GetPatient(ctx, tidB, f.A.Patient.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("tenant B reading tenant A's patient: got %v, want ErrNotFound", err)
	}

	// Each tenant can fetch its own patient.
	if got, err := s.GetPatient(ctx, tidA, f.A.Patient.ID); err != nil || got.ID != f.A.Patient.ID {
		t.Fatalf("tenant A reading own patient: %v / %v", err, got)
	}
}

func TestTenantIsolation_PatientByEmail(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)

	// A's tenant id, looking up B's email, must miss.
	if _, err := s.GetPatientByEmail(ctx, tidA, f.B.Patient.Email); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-tenant email lookup: got %v, want ErrNotFound", err)
	}
}

func TestTenantIsolation_Physician(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)
	tidB := TenantID(f.B.Tenant.ID)

	if _, err := s.GetPhysician(ctx, tidA, f.B.Physician.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-tenant physician get: got %v", err)
	}
	if _, err := s.GetPhysicianByEmail(ctx, tidB, f.A.Physician.Email); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-tenant physician email lookup: got %v", err)
	}
}

func TestTenantIsolation_PatientsByPhysician(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)
	tidB := TenantID(f.B.Tenant.ID)

	// Listing A's patients under A's tenant returns exactly A's patient.
	got, err := s.ListPatientsByPhysician(ctx, tidA, f.A.Physician.ID)
	if err != nil {
		t.Fatalf("list A patients: %v", err)
	}
	if len(got) != 1 || got[0].ID != f.A.Patient.ID {
		t.Fatalf("A patients = %+v, want exactly A's patient", got)
	}

	// Looking up B's physician under A's tenant returns nothing.
	got, err = s.ListPatientsByPhysician(ctx, tidA, f.B.Physician.ID)
	if err != nil {
		t.Fatalf("list B physician under A: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("cross-tenant physician panel leaked: %+v", got)
	}

	// And the reverse.
	got, err = s.ListPatientsByPhysician(ctx, tidB, f.A.Physician.ID)
	if err != nil {
		t.Fatalf("list A physician under B: %v", err)
	}
	if len(got) != 0 {
		t.Fatalf("cross-tenant physician panel leaked: %+v", got)
	}
}

func TestTenantIsolation_Conversations(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)
	tidB := TenantID(f.B.Tenant.ID)

	if _, err := s.GetConversation(ctx, tidA, f.B.Conversation.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-tenant conversation get: got %v", err)
	}

	gotA, err := s.ListConversationsByPatient(ctx, tidA, f.A.Patient.ID)
	if err != nil {
		t.Fatalf("list A conversations: %v", err)
	}
	if len(gotA) != 1 || gotA[0].ID != f.A.Conversation.ID {
		t.Fatalf("A conversations = %+v", gotA)
	}

	// A's patient id under B's tenant returns no conversations.
	leaked, err := s.ListConversationsByPatient(ctx, tidB, f.A.Patient.ID)
	if err != nil {
		t.Fatalf("cross-tenant conv list: %v", err)
	}
	if len(leaked) != 0 {
		t.Fatalf("cross-tenant conversation list leaked: %+v", leaked)
	}
}

func TestTenantIsolation_Messages(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)
	tidB := TenantID(f.B.Tenant.ID)

	gotA, err := s.ListMessagesByConversation(ctx, tidA, f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("list A messages: %v", err)
	}
	if len(gotA) != 1 || gotA[0].Content != "hello a" {
		t.Fatalf("A messages = %+v", gotA)
	}

	leaked, err := s.ListMessagesByConversation(ctx, tidB, f.A.Conversation.ID)
	if err != nil {
		t.Fatalf("cross-tenant msg list: %v", err)
	}
	if len(leaked) != 0 {
		t.Fatalf("cross-tenant message list leaked: %+v", leaked)
	}
}

func TestTenantIsolation_Recommendations(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)
	tidB := TenantID(f.B.Tenant.ID)

	if _, err := s.GetRecommendation(ctx, tidA, f.B.Recommendation.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("cross-tenant recommendation get: got %v", err)
	}

	queue, err := s.ListRecommendationsByState(ctx, tidA, "PENDING_REVIEW")
	if err != nil {
		t.Fatalf("queue A: %v", err)
	}
	if len(queue) != 1 || queue[0].ID != f.A.Recommendation.ID {
		t.Fatalf("queue A = %+v, want exactly A's recommendation", queue)
	}

	queueB, err := s.ListRecommendationsByState(ctx, tidB, "PENDING_REVIEW")
	if err != nil {
		t.Fatalf("queue B: %v", err)
	}
	if len(queueB) != 1 || queueB[0].ID != f.B.Recommendation.ID {
		t.Fatalf("queue B = %+v, want exactly B's recommendation", queueB)
	}
}

func TestTenantIsolation_AuditEvents(t *testing.T) {
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)

	actorID := f.A.Physician.ID
	if _, err := s.CreateAuditEvent(ctx, tidA, AuditEvent{
		ActorType: "physician",
		ActorID:   &actorID,
		EventType: "recommendation.reviewed",
	}); err != nil {
		t.Fatalf("create audit event: %v", err)
	}

	// A cross-tenant write is allowed at the SQL level (the function takes a
	// tenant id and trusts it), but rows written under tenant A's id are
	// only visible under tenant A. The invariant under test is that the
	// caller cannot fetch them under the wrong tenant id.
	var count int
	if err := pool.QueryRow(ctx,
		`SELECT count(*) FROM audit_events WHERE tenant_id = $1`,
		f.B.Tenant.ID.UUID(),
	).Scan(&count); err != nil {
		t.Fatalf("count B audits: %v", err)
	}
	if count != 0 {
		t.Fatalf("audit event leaked into tenant B: count=%d", count)
	}
}

func TestSchemaRejectsCrossTenantParent(t *testing.T) {
	// The composite (tenant_id, parent_id) FKs added in 0001_init mean a
	// conversation cannot be written under tenant A pointing at a patient
	// row whose tenant_id is B — defence-in-depth against an app bug that
	// passed the wrong tenant_id to the store.
	pool := testPool(t)
	s := New(pool)
	f := setupFixture(t, s)
	ctx := context.Background()

	tidA := TenantID(f.A.Tenant.ID)
	if _, err := s.CreateConversation(ctx, tidA, f.B.Patient.ID, "cross-tenant probe"); err == nil {
		t.Fatalf("schema accepted a conversation whose patient belongs to a different tenant")
	}
}
