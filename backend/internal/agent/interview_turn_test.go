// Package agent — internal test file for interview-turn generation (Task 1.2).
//
// This file uses "package agent" (not "package agent_test") so it can access
// the unexported generateInterviewTurn and interviewTurnCapReached symbols.
// DB-backed tests reuse the same TEST_DATABASE_URL convention as drafter_test.go
// but define their own helpers to avoid cross-package symbol conflicts.
package agent

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/markolonius/housecall/backend/internal/migrate"
	"github.com/markolonius/housecall/backend/internal/store"
)

// ---------------------------------------------------------------------------
// Internal test helpers
// ---------------------------------------------------------------------------

// itTestPool returns a pool connected to TEST_DATABASE_URL with migrations
// applied. Skips when the env var is unset.
func itTestPool(t *testing.T) *pgxpool.Pool {
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

	if _, err := migrate.Apply(ctx, conn, os.DirFS(itMigrationsDir(t))); err != nil {
		t.Fatalf("migrate: %v", err)
	}

	pool, err := pgxpool.New(ctx, dsn)
	if err != nil {
		t.Fatalf("pool: %v", err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func itMigrationsDir(t *testing.T) string {
	t.Helper()
	_, file, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller failed")
	}
	// agent/ → backend/migrations
	return filepath.Join(filepath.Dir(file), "..", "..", "migrations")
}

// spyClient captures the messages passed to Complete so tests can assert the
// model call was assembled correctly. It is intentionally separate from the
// stubClient in drafter_test.go (different package) and records ALL calls.
type spyClient struct {
	// captured holds the message slices from each Complete call, in order.
	captured [][]Message
	text     string
	err      error
}

func (s *spyClient) Complete(_ context.Context, msgs []Message) (string, error) {
	// Take a copy so later modifications by the caller don't affect captured.
	cp := make([]Message, len(msgs))
	copy(cp, msgs)
	s.captured = append(s.captured, cp)
	return s.text, s.err
}

// itSetupConversation creates the minimum DB rows needed to exercise
// generateInterviewTurn: one tenant, one patient, one conversation, and the
// given messages.
type itFixture struct {
	TenantID store.TenantID
	Conv     store.Conversation
}

func itSetupConversation(t *testing.T, s *store.Store, messages []struct{ Role, Content string }) itFixture {
	t.Helper()
	ctx := context.Background()
	suffix := uuid.New().String()

	tenant, err := s.CreateTenant(ctx, "dtc", "it-test-"+suffix)
	if err != nil {
		t.Fatalf("create tenant: %v", err)
	}
	tid := store.TenantID(tenant.ID)

	patient, err := s.CreatePatient(ctx, tid, store.Patient{
		Email:        "p+" + suffix + "@it.test",
		FullName:     "Test Patient",
		State:        "CA",
		PasswordHash: "hash",
	})
	if err != nil {
		t.Fatalf("create patient: %v", err)
	}

	conv, err := s.CreateConversation(ctx, tid, patient.ID, "interview test")
	if err != nil {
		t.Fatalf("create conversation: %v", err)
	}

	for _, m := range messages {
		if _, err := s.CreateMessage(ctx, tid, conv.ID, m.Role, m.Content); err != nil {
			t.Fatalf("create message role=%s: %v", m.Role, err)
		}
	}

	return itFixture{TenantID: tid, Conv: conv}
}

// stubNotifierNoop satisfies PhysicianNotifier and PatientNotifier for Drafter
// construction in tests that do not exercise notification paths.
type stubNotifierNoop struct{}

func (stubNotifierNoop) SendToPhysicians(_ string, _ []byte) {}
func (stubNotifierNoop) SendToPatient(_, _ string, _ []byte) {}

// ---------------------------------------------------------------------------
// Tests: generateInterviewTurn
// ---------------------------------------------------------------------------

// TestGenerateInterviewTurn_LeadingSystemPrompt asserts that generateInterviewTurn
// always places InterviewSystemPrompt as the first (system-role) message
// regardless of what is in the conversation history.
func TestGenerateInterviewTurn_LeadingSystemPrompt(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	msgs := []struct{ Role, Content string }{
		{"user", "I have a headache."},
	}
	f := itSetupConversation(t, s, msgs)

	spy := &spyClient{text: "When did it start?"}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	_, err := d.generateInterviewTurn(context.Background(), f.TenantID, f.Conv)
	if err != nil {
		t.Fatalf("generateInterviewTurn: unexpected error: %v", err)
	}

	if len(spy.captured) != 1 {
		t.Fatalf("expected exactly 1 Complete call, got %d", len(spy.captured))
	}
	got := spy.captured[0]
	if len(got) == 0 {
		t.Fatal("model message slice is empty; expected at least the system prompt")
	}
	first := got[0]
	if first.Role != "system" {
		t.Errorf("first message role = %q, want %q", first.Role, "system")
	}
	if first.Content != InterviewSystemPrompt {
		t.Errorf("first message content is not InterviewSystemPrompt (got %d chars, want %d chars)",
			len(first.Content), len(InterviewSystemPrompt))
	}
}

// TestGenerateInterviewTurn_ConversationHistory asserts that the full
// conversation history is appended after the system prompt, in order, with
// roles and content preserved.
func TestGenerateInterviewTurn_ConversationHistory(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	seedMsgs := []struct{ Role, Content string }{
		{"user", "I have a headache."},
		{"assistant", "When did it start?"},
		{"user", "Yesterday morning."},
	}
	f := itSetupConversation(t, s, seedMsgs)

	spy := &spyClient{text: "How would you rate the pain on a scale of 0-10?"}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	_, err := d.generateInterviewTurn(context.Background(), f.TenantID, f.Conv)
	if err != nil {
		t.Fatalf("generateInterviewTurn: unexpected error: %v", err)
	}

	if len(spy.captured) != 1 {
		t.Fatalf("expected exactly 1 Complete call, got %d", len(spy.captured))
	}
	got := spy.captured[0]

	// Message slice must be: 1 system + len(seedMsgs) history messages.
	wantLen := 1 + len(seedMsgs)
	if len(got) != wantLen {
		t.Fatalf("model message count = %d, want %d", len(got), wantLen)
	}

	// Verify system prompt is first.
	if got[0].Role != "system" || got[0].Content != InterviewSystemPrompt {
		t.Errorf("got[0] = {%q, %d chars}, want {system, InterviewSystemPrompt}", got[0].Role, len(got[0].Content))
	}

	// Verify conversation history follows in order.
	for i, want := range seedMsgs {
		m := got[i+1]
		if m.Role != want.Role {
			t.Errorf("got[%d].Role = %q, want %q", i+1, m.Role, want.Role)
		}
		if m.Content != want.Content {
			t.Errorf("got[%d].Content = %q, want %q", i+1, m.Content, want.Content)
		}
	}
}

// TestGenerateInterviewTurn_ReturnsModelText asserts that generateInterviewTurn
// returns exactly the string the model client returned.
func TestGenerateInterviewTurn_ReturnsModelText(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	f := itSetupConversation(t, s, []struct{ Role, Content string }{
		{"user", "My stomach hurts."},
	})

	const wantText = "I'm sorry to hear that. Can you point to where the pain is located?"
	spy := &spyClient{text: wantText}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	got, err := d.generateInterviewTurn(context.Background(), f.TenantID, f.Conv)
	if err != nil {
		t.Fatalf("generateInterviewTurn: unexpected error: %v", err)
	}
	if got != wantText {
		t.Errorf("returned text = %q, want %q", got, wantText)
	}
}

// TestGenerateInterviewTurn_PropagatesModelError asserts that a model client
// error is returned as-is so the caller can classify it via draftFailureReason.
func TestGenerateInterviewTurn_PropagatesModelError(t *testing.T) {
	pool := itTestPool(t)
	s := store.New(pool)

	f := itSetupConversation(t, s, []struct{ Role, Content string }{
		{"user", "My arm hurts."},
	})

	wantErr := &ModelError{StatusCode: 503}
	spy := &spyClient{err: wantErr}
	d := NewDrafter(spy, s, stubNotifierNoop{}, stubNotifierNoop{})

	text, err := d.generateInterviewTurn(context.Background(), f.TenantID, f.Conv)
	if err == nil {
		t.Fatal("expected error from model client, got nil")
	}
	if text != "" {
		t.Errorf("expected empty text on error, got %q", text)
	}
	var me *ModelError
	if !errors.As(err, &me) {
		t.Errorf("expected *ModelError, got %T", err)
	}
}

// ---------------------------------------------------------------------------
// Tests: interviewTurnCapReached (pure — no DB needed)
// ---------------------------------------------------------------------------

// TestInterviewTurnCapReached_BelowCap verifies that fewer assistant turns
// than the cap returns false.
func TestInterviewTurnCapReached_BelowCap(t *testing.T) {
	msgs := makeTestMessages(
		"user", "assistant", "user", "assistant", // 2 assistant turns
	)
	if interviewTurnCapReached(msgs, 3) {
		t.Error("expected false when assistant turns (2) < cap (3), got true")
	}
}

// TestInterviewTurnCapReached_AtCap verifies that exactly cap assistant turns
// returns true.
func TestInterviewTurnCapReached_AtCap(t *testing.T) {
	msgs := makeTestMessages(
		"user", "assistant", "user", "assistant", "user", "assistant", // 3 assistant turns
	)
	if !interviewTurnCapReached(msgs, 3) {
		t.Error("expected true when assistant turns (3) == cap (3), got false")
	}
}

// TestInterviewTurnCapReached_AboveCap verifies that more than cap assistant
// turns also returns true.
func TestInterviewTurnCapReached_AboveCap(t *testing.T) {
	msgs := makeTestMessages(
		"user", "assistant", "user", "assistant", "user", "assistant", "user", "assistant", // 4 assistant turns
	)
	if !interviewTurnCapReached(msgs, 3) {
		t.Error("expected true when assistant turns (4) > cap (3), got false")
	}
}

// TestInterviewTurnCapReached_NoAssistantTurns verifies that a conversation
// with only user messages never reaches the cap.
func TestInterviewTurnCapReached_NoAssistantTurns(t *testing.T) {
	msgs := makeTestMessages("user", "user", "user")
	if interviewTurnCapReached(msgs, 1) {
		t.Error("expected false for all-user conversation even with cap=1, got true")
	}
}

// TestInterviewTurnCapReached_EmptyConversation verifies an empty message
// slice never reaches the cap (as long as cap > 0).
func TestInterviewTurnCapReached_EmptyConversation(t *testing.T) {
	if interviewTurnCapReached(nil, DefaultMaxInterviewTurns) {
		t.Error("expected false for empty message slice, got true")
	}
}

// TestInterviewTurnCapReached_DefaultCap verifies the constant DefaultMaxInterviewTurns
// is 12 (documented production value).
func TestInterviewTurnCapReached_DefaultCap(t *testing.T) {
	const want = 12
	if DefaultMaxInterviewTurns != want {
		t.Errorf("DefaultMaxInterviewTurns = %d, want %d", DefaultMaxInterviewTurns, want)
	}
}

// TestInterviewTurnCapReached_SystemRoleNotCounted verifies that "system" role
// messages do not count toward the cap.
func TestInterviewTurnCapReached_SystemRoleNotCounted(t *testing.T) {
	msgs := makeTestMessages("system", "system", "system") // no assistant turns
	if interviewTurnCapReached(msgs, 1) {
		t.Error("system-role messages must not count toward the turn cap")
	}
}

// makeTestMessages builds a []store.Message slice from a list of roles, with
// placeholder content and zero UUIDs. It is a convenience for pure unit tests
// of interviewTurnCapReached that only care about the Role field.
func makeTestMessages(roles ...string) []store.Message {
	out := make([]store.Message, len(roles))
	for i, r := range roles {
		out[i] = store.Message{Role: r, Content: "content"}
	}
	return out
}
