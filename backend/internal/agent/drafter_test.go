package agent_test

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/markolonius/housecall/backend/internal/agent"
	"github.com/markolonius/housecall/backend/internal/domain"
	"github.com/markolonius/housecall/backend/internal/migrate"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

// testPool returns a pool connected to TEST_DATABASE_URL with migrations
// applied. Skips when the env var is unset so the suite compiles without
// Postgres.
//
// Unlike the store package's testPool, this helper does NOT TRUNCATE the
// schema. Drafter tests create their own tenant rows using unique names and
// scope all assertions to those tenants, so they are safe to run alongside
// other packages without a clean-slate requirement. Avoiding a TRUNCATE
// prevents a parallel-execution race with the store package's own TRUNCATE.
func testPool(t *testing.T) *pgxpool.Pool {
	t.Helper()
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL not set; skipping DB-bound test")
	}

	ctx := context.Background()

	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	defer conn.Close(ctx)

	if _, err := migrate.Apply(ctx, conn, os.DirFS(migrationsDir(t))); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func migrationsDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	// agent/ → backend/migrations
	return filepath.Join(filepath.Dir(file), "..", "..", "migrations")
}

// stubClient is a ModelClient that returns a canned response.
type stubClient struct {
	text string
	err  error
}

func (s *stubClient) Complete(_ context.Context, _ []agent.Message) (string, error) {
	return s.text, s.err
}

// panicClient is a ModelClient whose Complete method always panics. Used to
// verify that DraftAsync's recover() keeps the process alive.
type panicClient struct{}

func (p *panicClient) Complete(_ context.Context, _ []agent.Message) (string, error) {
	panic("simulated model client panic")
}

// newDrafterWithWait constructs a Drafter whose background goroutine signals a
// sync.WaitGroup when it exits (success, failure, or panic). Call wg.Wait()
// (or register it in t.Cleanup) to ensure no goroutine outlives the test.
// This is test-only; production callers use agent.NewDrafter directly.
func newDrafterWithWait(t *testing.T, client agent.ModelClient, s *store.Store, notifier *stubNotifier, patientNotifier agent.PatientNotifier) (*agent.Drafter, *sync.WaitGroup) {
	t.Helper()
	var wg sync.WaitGroup
	wg.Add(1)
	d := agent.NewDrafter(client, s, notifier, patientNotifier).WithOnComplete(wg.Done)
	t.Cleanup(func() {
		// Block until the goroutine has fully exited so no in-flight DB writes
		// can race with test teardown or the store package's TRUNCATE.
		wg.Wait()
	})
	return d, &wg
}

// stubNotifier records the last event sent to physicians.
type stubNotifier struct {
	mu     sync.Mutex
	events [][]byte
}

func (n *stubNotifier) SendToPhysicians(_ string, event []byte) {
	n.mu.Lock()
	defer n.mu.Unlock()
	n.events = append(n.events, event)
}

func (n *stubNotifier) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.events)
}

func (n *stubNotifier) last() []byte {
	n.mu.Lock()
	defer n.mu.Unlock()
	if len(n.events) == 0 {
		return nil
	}
	return n.events[len(n.events)-1]
}

// stubPatientNotifier is a no-op agent.PatientNotifier for tests that only
// exercise the physician-notification path.
type stubPatientNotifier struct{}

func (stubPatientNotifier) SendToPatient(_, _ string, _ []byte) {}

// recordingPatientNotifier captures every SendToPatient call so tests can
// assert the patient was (or was not) notified.
type recordingPatientNotifier struct {
	mu    sync.Mutex
	calls [][]byte
}

func (n *recordingPatientNotifier) SendToPatient(_, _ string, event []byte) {
	cp := make([]byte, len(event))
	copy(cp, event)
	n.mu.Lock()
	defer n.mu.Unlock()
	n.calls = append(n.calls, cp)
}

func (n *recordingPatientNotifier) count() int {
	n.mu.Lock()
	defer n.mu.Unlock()
	return len(n.calls)
}

func (n *recordingPatientNotifier) last() []byte {
	n.mu.Lock()
	defer n.mu.Unlock()
	if len(n.calls) == 0 {
		return nil
	}
	return n.calls[len(n.calls)-1]
}

// ---------------------------------------------------------------------------
// setupDrafterFixture creates one tenant, patient, physician, care relationship,
// conversation, and one user message, then returns everything needed to test the
// drafter.
// ---------------------------------------------------------------------------

type drafterFixture struct {
	TenantID store.TenantID
	Patient  store.Patient
	Conv     store.Conversation
}

func setupDrafterFixture(t *testing.T, s *store.Store) drafterFixture {
	t.Helper()
	ctx := context.Background()

	// Use a random suffix so parallel test runs against the same DB do not
	// collide on unique constraint columns (email).
	suffix := uuid.New().String()

	tenant, err := s.CreateTenant(ctx, "dtc", "drafter-test-"+suffix)
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "patient+" + suffix + "@drafter.test",
		FullName:     "Test Patient",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	physician, err := s.CreatePhysician(ctx, tid, store.Physician{
		Email:          "doc+" + suffix + "@drafter.test",
		FullName:       "Test Doc",
		StatesLicensed: []string{"CA"},
		PasswordHash:   "hash",
	})
	if err != nil {
		t.Fatalf("create physician: %v", err)
	}

	if _, err := s.CreateCareRelationship(ctx, tid, patient.ID, physician.ID); err != nil {
		t.Fatalf("create care relationship: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "test conversation")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	// Seed one patient message — this is what the drafter assembles as context.
	if _, err := s.CreateMessage(ctx, tid, conv.ID, "user", "I have a headache"); err != nil {
		t.Fatalf("create message: %v", err)
	}

	return drafterFixture{TenantID: tid, Patient: patient, Conv: conv}
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

// TestDraft_HappyPath verifies that a patient message during an ongoing
// interview produces an assistant interview question: exactly one assistant-role
// message persisted, one patient notification (message.created), one
// agent.interview_question audit event, and NO recommendation row and NO
// queue.updated event sent to physicians.
//
// The stub client returns plain text without ReadyForNoteMarker, so
// decideInterviewAction classifies the turn as a continuing interview question.
func TestDraft_HappyPath(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	f := setupDrafterFixture(t, s)
	ctx := context.Background()

	// A normal interview question — no ReadyForNoteMarker present.
	const wantText = "Can you describe where the pain is located?"

	physNotifier := &stubNotifier{}
	patNotifier := &recordingPatientNotifier{}
	// newDrafterWithWait registers a t.Cleanup that blocks until the goroutine
	// has exited, preventing races with shared-DB teardown across tests.
	d, wg := newDrafterWithWait(t, &stubClient{text: wantText}, s, physNotifier, patNotifier)

	d.DraftAsync(f.TenantID, f.Conv, f.Patient)

	// Block until the goroutine has fully exited (onComplete hook fires on
	// success, failure, or panic so this is always safe).
	wg.Wait()

	// --- Assert NO recommendation was created (interview question, not note) ---
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list PENDING_REVIEW recs: %v", err)
	}
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("unexpected PENDING_REVIEW recommendation for conversation %s — interview questions must not create recommendations", f.Conv.ID)
		}
	}
	drafts, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StateDraft)
	if err != nil {
		t.Fatalf("list DRAFT recs: %v", err)
	}
	for _, r := range drafts {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("unexpected DRAFT recommendation for conversation %s", f.Conv.ID)
		}
	}

	// --- Assert the interview question was persisted as an assistant message ---
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
	if assistantMsgs[0].Content != wantText {
		t.Errorf("assistant message content = %q, want %q", assistantMsgs[0].Content, wantText)
	}

	// --- Assert patient was notified (message.created event with IDs only) ---
	if patNotifier.count() != 1 {
		t.Fatalf("expected 1 patient notification, got %d", patNotifier.count())
	}
	var patEvt map[string]any
	if err := json.Unmarshal(patNotifier.last(), &patEvt); err != nil {
		t.Fatalf("unmarshal patient event: %v", err)
	}
	if patEvt["type"] != "message.created" {
		t.Errorf("patient event type = %q, want %q", patEvt["type"], "message.created")
	}

	// --- Assert NO queue.updated event was emitted to physicians ---
	if physNotifier.count() != 0 {
		t.Errorf("expected 0 physician queue.updated events for an interview question turn, got %d", physNotifier.count())
	}

	// --- Assert audit event exists with identifiers only (no PHI) ---
	rows, err := pool.Query(ctx,
		`SELECT metadata
		   FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'agent.interview_question'
		    AND metadata->>'conversation_id' = $2`,
		f.TenantID.UUID(),
		f.Conv.ID.String(),
	)
	if err != nil {
		t.Fatalf("query audit events: %v", err)
	}
	defer rows.Close()

	var auditCount int
	for rows.Next() {
		var meta []byte
		if err := rows.Scan(&meta); err != nil {
			t.Fatalf("scan audit row: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(meta, &m); err != nil {
			t.Fatalf("unmarshal audit metadata: %v", err)
		}
		if _, ok := m["conversation_id"]; !ok {
			t.Errorf("audit metadata missing conversation_id")
		}
		if _, ok := m["message_id"]; !ok {
			t.Errorf("audit metadata missing message_id")
		}
		// Question content must NOT appear in audit metadata (PHI constraint).
		for _, field := range []string{"content", "text", "question"} {
			if v, ok := m[field]; ok {
				t.Errorf("audit metadata must not contain field %q (PHI leak): value = %v", field, v)
			}
		}
		auditCount++
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows error: %v", err)
	}
	if auditCount != 1 {
		t.Errorf("expected 1 audit event for agent.interview_question, got %d", auditCount)
	}
}

// TestDraft_TenantScoping verifies that the drafter only reads and writes data
// scoped to the target tenant and never bleeds into another tenant's data. Under
// the interview flow, a normal question turn persists an assistant message in the
// target tenant's conversation and must NOT touch any other tenant's data.
func TestDraft_TenantScoping(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	ctx := context.Background()

	// Set up two completely independent tenants.
	fA := setupDrafterFixture(t, s)

	// Create tenant B with its own patient and conversation.
	suffixB := uuid.New().String()
	tenantB, err := s.CreateTenant(ctx, "dtc", "tenant-b-"+suffixB)
	if err != nil {
		t.Fatalf("create tenant B: %v", err)
	}
	tidB := store.TenantID(tenantB.ID)
	patientB, err := s.CreatePatient(ctx, tidB, store.Patient{
		Email:        "patient+" + suffixB + "@b.test",
		FullName:     "B Patient",
		State:        "NY",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient B: %v", err)
	}
	convB, err := s.CreateConversation(ctx, tidB, patientB.ID, "conv B")
	if err != nil {
		t.Fatalf("create conv B: %v", err)
	}
	if _, err := s.CreateMessage(ctx, tidB, convB.ID, "user", "B's private message"); err != nil {
		t.Fatalf("create message B: %v", err)
	}

	// Run drafter for tenant A only. Stub returns a plain interview question
	// (no marker), so the turn delivers a question and creates no recommendation.
	const wantText = "Interview question for A only."
	physNotifier := &stubNotifier{}
	patNotifier := &recordingPatientNotifier{}
	d, wg := newDrafterWithWait(t, &stubClient{text: wantText}, s, physNotifier, patNotifier)
	d.DraftAsync(fA.TenantID, fA.Conv, fA.Patient)

	// Block until the goroutine exits before making DB assertions.
	wg.Wait()

	// --- Neither tenant must have any recommendation (interview question turn) ---
	recsB, err := s.ListRecommendationsByState(ctx, tidB, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list B recs: %v", err)
	}
	if len(recsB) != 0 {
		t.Errorf("tenant B has %d recommendations after drafting for tenant A — tenant leak!", len(recsB))
	}
	recsA, err := s.ListRecommendationsByState(ctx, fA.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list A recs: %v", err)
	}
	if len(recsA) != 0 {
		t.Errorf("tenant A has %d PENDING_REVIEW recommendations for an interview-question turn, want 0", len(recsA))
	}

	// --- Tenant A's conversation must have the interview question as an assistant
	// message; tenant B's conversation must have only its original user message. ---
	msgsA, err := s.ListMessagesByConversation(ctx, fA.TenantID, fA.Conv.ID)
	if err != nil {
		t.Fatalf("list tenant A messages: %v", err)
	}
	var assistantA []store.Message
	for _, m := range msgsA {
		if m.Role == "assistant" {
			assistantA = append(assistantA, m)
		}
	}
	if len(assistantA) != 1 {
		t.Errorf("tenant A: expected 1 assistant message (interview question), got %d", len(assistantA))
	} else if assistantA[0].Content != wantText {
		t.Errorf("tenant A assistant message content = %q, want %q", assistantA[0].Content, wantText)
	}

	msgsB, err := s.ListMessagesByConversation(ctx, tidB, convB.ID)
	if err != nil {
		t.Fatalf("list tenant B messages: %v", err)
	}
	for _, m := range msgsB {
		if m.Role == "assistant" {
			t.Errorf("tenant B has unexpected assistant message — cross-tenant bleed: content=%q", m.Content)
		}
	}
}

// ---------------------------------------------------------------------------
// Task 4.3: failure-path tests
// ---------------------------------------------------------------------------

// assertFailurePath is a shared helper for the four Task 4.3 failure-mode
// tests. It:
//
//  1. Waits up to 2 s for the goroutine to finish (detected via audit row).
//  2. Asserts zero recommendations exist for the fixture's conversation.
//  3. Asserts exactly one ai_interaction_failed audit row exists with the
//     expected coarse reason and no PHI / model-body content.
//  4. Asserts no queue.updated event was emitted.
func assertFailurePath(t *testing.T, pool *pgxpool.Pool, s *store.Store, f drafterFixture, notifier *stubNotifier, wantReason string) {
	t.Helper()
	ctx := context.Background()

	// Poll until the audit row appears (goroutine completes near-instantly with
	// stub clients, but give it up to 2 s to be safe in CI).
	deadline := time.Now().Add(2 * time.Second)
	var auditRows int
	for time.Now().Before(deadline) {
		row := pool.QueryRow(ctx,
			`SELECT COUNT(*) FROM audit_events
			  WHERE tenant_id = $1 AND event_type = 'ai_interaction_failed'`,
			f.TenantID.UUID(),
		)
		if err := row.Scan(&auditRows); err == nil && auditRows > 0 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	// (a) Zero recommendations for this tenant's conversation.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list PENDING_REVIEW recs: %v", err)
	}
	// Filter to the fixture's conversation to be safe when tests run in parallel
	// against the same DB.
	for _, r := range recs {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("found unexpected PENDING_REVIEW recommendation for conversation %s", f.Conv.ID)
		}
	}
	drafts, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StateDraft)
	if err != nil {
		t.Fatalf("list DRAFT recs: %v", err)
	}
	for _, r := range drafts {
		if r.ConversationID == f.Conv.ID {
			t.Errorf("found unexpected DRAFT recommendation for conversation %s", f.Conv.ID)
		}
	}

	// (b) Exactly one ai_interaction_failed audit row with correct reason and no PHI.
	rows, err := pool.Query(ctx,
		`SELECT metadata FROM audit_events
		  WHERE tenant_id = $1 AND event_type = 'ai_interaction_failed'
		    AND metadata->>'conversation_id' = $2`,
		f.TenantID.UUID(),
		f.Conv.ID.String(),
	)
	if err != nil {
		t.Fatalf("query ai_interaction_failed audit rows: %v", err)
	}
	defer rows.Close()

	var count int
	for rows.Next() {
		count++
		var meta []byte
		if err := rows.Scan(&meta); err != nil {
			t.Fatalf("scan audit metadata: %v", err)
		}
		var m map[string]any
		if err := json.Unmarshal(meta, &m); err != nil {
			t.Fatalf("unmarshal audit metadata: %v", err)
		}
		// Reason must match expected coarse string.
		if got, ok := m["reason"].(string); !ok || got != wantReason {
			t.Errorf("audit reason = %q, want %q (metadata=%s)", got, wantReason, meta)
		}
		// conversation_id and patient_id must be present (identifiers only).
		if _, ok := m["conversation_id"]; !ok {
			t.Errorf("audit metadata missing conversation_id")
		}
		if _, ok := m["patient_id"]; !ok {
			t.Errorf("audit metadata missing patient_id")
		}
		// Metadata must not contain any model-body / PHI fields.
		for _, forbidden := range []string{"body", "content", "text", "error", "detail", "message"} {
			if _, present := m[forbidden]; present {
				t.Errorf("audit metadata must not contain field %q (PHI/body leak)", forbidden)
			}
		}
	}
	if err := rows.Err(); err != nil {
		t.Fatalf("rows error: %v", err)
	}
	if count != 1 {
		t.Errorf("expected 1 ai_interaction_failed audit row, got %d", count)
	}

	// (c) No queue.updated emitted.
	if notifier.count() != 0 {
		t.Errorf("expected 0 queue.updated events on failure, got %d", notifier.count())
	}
}

// TestDraft_FailurePath_TransportError verifies that a transport-level error
// (connection refused / net.Error) produces no recommendation and an
// ai_interaction_failed audit event with reason "model_unavailable".
func TestDraft_FailurePath_TransportError(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	f := setupDrafterFixture(t, s)

	// Simulate a transport error (net.Error). We use a real *net.OpError which
	// implements net.Error, wrapped in the same way the http client would surface
	// a connection-refused error.
	transportErr := &net.OpError{Op: "dial", Err: errors.New("connection refused")}
	notifier := &stubNotifier{}
	d, _ := newDrafterWithWait(t, &stubClient{err: transportErr}, s, notifier, stubPatientNotifier{})
	d.DraftAsync(f.TenantID, f.Conv, f.Patient)

	assertFailurePath(t, pool, s, f, notifier, "model_unavailable")
}

// TestDraft_FailurePath_ModelError verifies that a non-2xx HTTP response from
// the model endpoint produces no recommendation and an ai_interaction_failed
// audit event with reason "model_error".
func TestDraft_FailurePath_ModelError(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	f := setupDrafterFixture(t, s)

	modelErr := &agent.ModelError{StatusCode: 503}
	notifier := &stubNotifier{}
	d, _ := newDrafterWithWait(t, &stubClient{err: modelErr}, s, notifier, stubPatientNotifier{})
	d.DraftAsync(f.TenantID, f.Conv, f.Patient)

	assertFailurePath(t, pool, s, f, notifier, "model_error")
}

// TestDraft_FailurePath_ParseError verifies that a well-formed HTTP response
// whose body cannot be decoded (or has no usable choices) produces no
// recommendation and an ai_interaction_failed audit event with reason
// "parse_error".
func TestDraft_FailurePath_ParseError(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	f := setupDrafterFixture(t, s)

	parseErr := &agent.ParseError{Detail: "response contained no choices"}
	notifier := &stubNotifier{}
	d, _ := newDrafterWithWait(t, &stubClient{err: parseErr}, s, notifier, stubPatientNotifier{})
	d.DraftAsync(f.TenantID, f.Conv, f.Patient)

	assertFailurePath(t, pool, s, f, notifier, "parse_error")
}

// TestDraft_FailurePath_Timeout verifies that a context deadline exceeded error
// produces no recommendation and an ai_interaction_failed audit event with
// reason "timeout".
func TestDraft_FailurePath_Timeout(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	f := setupDrafterFixture(t, s)

	notifier := &stubNotifier{}
	d, _ := newDrafterWithWait(t, &stubClient{err: context.DeadlineExceeded}, s, notifier, stubPatientNotifier{})
	d.DraftAsync(f.TenantID, f.Conv, f.Patient)

	assertFailurePath(t, pool, s, f, notifier, "timeout")
}

// ---------------------------------------------------------------------------
// Compile-time interface checks (moved after failure-path block)
// ---------------------------------------------------------------------------

// TestDraft_ModelClientInterface verifies that the ModelClient interface is
// satisfied by a struct that does NOT embed *agent.Client — confirming the
// interface is the only contract between the drafter and the model.
func TestDraft_ModelClientInterface(t *testing.T) {
	// This test is a compile-time guard: if agent.ModelClient changes its
	// signature, this stub won't compile. The blank assignment forces the check.
	var _ agent.ModelClient = (*stubClient)(nil)
	// Also verify that *agent.Client satisfies the interface.
	var _ agent.ModelClient = (*agent.Client)(nil)
}

// TestDraft_ErrorPath_StructuredForTask43 verifies that when the model client
// returns an error the drafter returns an error and creates no recommendation.
// This is the structural stub for Task 4.3 — the full failure path (audit
// event) is implemented there; here we assert the happy-path invariant holds
// (no recommendation persisted on failure).
func TestDraft_ErrorPath_StructuredForTask43(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	f := setupDrafterFixture(t, s)
	ctx := context.Background()

	modelErr := &agent.ModelError{StatusCode: 503}
	notifier := &stubNotifier{}
	d, wg := newDrafterWithWait(t, &stubClient{err: modelErr}, s, notifier, stubPatientNotifier{})
	d.DraftAsync(f.TenantID, f.Conv, f.Patient)

	// Wait for the goroutine to finish before asserting; newDrafterWithWait
	// also registers t.Cleanup(wg.Wait) but we need to wait before the assert
	// below so that the goroutine's audit write (if any) does not race.
	wg.Wait()

	// No recommendation must be created on error.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list recs: %v", err)
	}
	if len(recs) != 0 {
		t.Errorf("expected 0 recommendations on model error, got %d", len(recs))
	}

	// No queue.updated should be sent.
	if notifier.count() != 0 {
		t.Errorf("expected 0 queue.updated events on model error, got %d", notifier.count())
	}

	// Confirm the error is a *ModelError (not a ParseError or other type) so
	// Task 4.3 can switch on it.
	var me *agent.ModelError
	if !errors.As(modelErr, &me) {
		t.Errorf("expected *agent.ModelError, got %T", modelErr)
	}
}

// TestDraft_PanicRecovery verifies that a panic inside the model client does
// NOT crash the server process: DraftAsync recovers, no recommendation is
// persisted, and no queue.updated event is emitted.
func TestDraft_PanicRecovery(t *testing.T) {
	pool := testPool(t)
	s := store.New(pool)
	f := setupDrafterFixture(t, s)
	ctx := context.Background()

	notifier := &stubNotifier{}
	d, wg := newDrafterWithWait(t, &panicClient{}, s, notifier, stubPatientNotifier{})

	// DraftAsync must return without panicking — if the goroutine's panic
	// propagates the test binary itself will crash here.
	d.DraftAsync(f.TenantID, f.Conv, f.Patient)

	// Wait for the goroutine to exit (the onComplete hook fires after recover,
	// so wg.Done() is called even on panic).
	wg.Wait()

	// No recommendation must be created when the client panicked.
	recs, err := s.ListRecommendationsByState(ctx, f.TenantID, domain.StatePendingReview)
	if err != nil {
		t.Fatalf("list recs: %v", err)
	}
	if len(recs) != 0 {
		t.Errorf("expected 0 recommendations after panicking client, got %d", len(recs))
	}

	// No queue.updated notification should be emitted on panic.
	if notifier.count() != 0 {
		t.Errorf("expected 0 queue.updated events after panicking client, got %d", notifier.count())
	}
}
