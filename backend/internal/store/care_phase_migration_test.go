package store

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"testing/fstest"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/markolonius/housecall/backend/internal/migrate"
)

// TestCarePhaseMigration_Backfill seeds conversations and recommendations
// against the pre-care_phase schema (migrations 0001-0003 only, mirroring
// genuine legacy rows that predate the column), then applies migration 0004
// in isolation and asserts the backfilled care_phase matches the precedence
// rules in openspec/changes/add-agent-care-loop/design.md: a delivered
// recommendation always wins, a pending one wins over nothing, and a
// rejected-only conversation is left at INTAKE (REJECTED never promotes a
// row). This test intentionally resets the public schema rather than
// reusing testPool's "apply everything" helper, because the behaviour under
// test only occurs once, at the moment the column is introduced.
func TestCarePhaseMigration_Backfill(t *testing.T) {
	dsn := os.Getenv("TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("TEST_DATABASE_URL not set; skipping DB-bound test")
	}

	ctx := context.Background()
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	// Registered before the reapply cleanup below so it runs *after* it
	// (t.Cleanup functions run in LIFO order): the connection must still be
	// open when the full schema is reapplied.
	t.Cleanup(func() { conn.Close(context.Background()) })

	// Reset to a bare schema so this test controls exactly which migrations
	// are applied, independent of every other test in this package.
	if _, err := conn.Exec(ctx, `DROP SCHEMA public CASCADE; CREATE SCHEMA public`); err != nil {
		t.Fatalf("reset schema: %v", err)
	}
	// Leave the DB back on the full, latest schema for every test that runs
	// after this one (testPool()'s migrate.Apply is a no-op for versions
	// already recorded in schema_migrations).
	t.Cleanup(func() {
		if _, err := migrate.Apply(context.Background(), conn, os.DirFS(migrationsDir(t))); err != nil {
			t.Fatalf("re-apply full schema after backfill test: %v", err)
		}
	})

	preCarePhase := partialMigrationFS(t,
		"0001_init.sql",
		"0002_message_idempotency.sql",
		"0003_soap_note_payload.sql",
	)
	if _, err := migrate.Apply(ctx, conn, preCarePhase); err != nil {
		t.Fatalf("apply pre-care_phase migrations: %v", err)
	}

	tenantID := uuid.New()
	if _, err := conn.Exec(ctx,
		`INSERT INTO tenants (id, kind, name) VALUES ($1, 'dtc', 'backfill-test')`,
		tenantID,
	); err != nil {
		t.Fatalf("seed tenant: %v", err)
	}
	patientID := uuid.New()
	if _, err := conn.Exec(ctx,
		`INSERT INTO patients (id, tenant_id, email, full_name, state, password_hash)
		 VALUES ($1, $2, 'patient@backfill.test', 'Backfill Patient', 'PA', 'hash')`,
		patientID, tenantID,
	); err != nil {
		t.Fatalf("seed patient: %v", err)
	}

	newConversation := func(title string) uuid.UUID {
		id := uuid.New()
		if _, err := conn.Exec(ctx,
			`INSERT INTO conversations (id, tenant_id, patient_id, title) VALUES ($1, $2, $3, $4)`,
			id, tenantID, patientID, title,
		); err != nil {
			t.Fatalf("seed conversation %q: %v", title, err)
		}
		return id
	}
	newRecommendation := func(conversationID uuid.UUID, state string) {
		if _, err := conn.Exec(ctx,
			`INSERT INTO recommendations
			   (tenant_id, conversation_id, patient_id, state, payload_type, payload, draft_content)
			 VALUES ($1, $2, $3, $4, 'guidance', $5, 'draft')`,
			tenantID, conversationID, patientID, state, json.RawMessage(`{"text":"x"}`),
		); err != nil {
			t.Fatalf("seed recommendation state=%s: %v", state, err)
		}
	}

	noRecs := newConversation("no recommendations")

	draftOnly := newConversation("draft only")
	newRecommendation(draftOnly, "DRAFT")

	rejectedOnly := newConversation("rejected only")
	newRecommendation(rejectedOnly, "REJECTED")

	pending := newConversation("pending review")
	newRecommendation(pending, "PENDING_REVIEW")

	delivered := newConversation("delivered")
	newRecommendation(delivered, "DELIVERED")

	deliveredAndPending := newConversation("delivered and pending")
	newRecommendation(deliveredAndPending, "DELIVERED")
	newRecommendation(deliveredAndPending, "PENDING_REVIEW")

	carePhaseMigration := partialMigrationFS(t, "0004_care_phase.sql")
	if _, err := migrate.Apply(ctx, conn, carePhaseMigration); err != nil {
		t.Fatalf("apply care_phase migration: %v", err)
	}

	cases := []struct {
		name string
		id   uuid.UUID
		want string
	}{
		{"no recommendations stays INTAKE", noRecs, "INTAKE"},
		{"draft-only recommendation stays INTAKE", draftOnly, "INTAKE"},
		{"rejected-only recommendation stays INTAKE", rejectedOnly, "INTAKE"},
		{"pending recommendation becomes AWAITING_REVIEW", pending, "AWAITING_REVIEW"},
		{"delivered recommendation becomes PLAN_DELIVERED", delivered, "PLAN_DELIVERED"},
		{"delivered beats pending", deliveredAndPending, "PLAN_DELIVERED"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var got string
			if err := conn.QueryRow(ctx,
				`SELECT care_phase FROM conversations WHERE id = $1`, tc.id,
			).Scan(&got); err != nil {
				t.Fatalf("query care_phase: %v", err)
			}
			if got != tc.want {
				t.Errorf("care_phase = %q, want %q", got, tc.want)
			}
		})
	}

	t.Run("new conversation defaults to INTAKE", func(t *testing.T) {
		id := newConversation("post-migration")
		var got string
		if err := conn.QueryRow(ctx,
			`SELECT care_phase FROM conversations WHERE id = $1`, id,
		).Scan(&got); err != nil {
			t.Fatalf("query care_phase: %v", err)
		}
		if got != "INTAKE" {
			t.Errorf("care_phase = %q, want INTAKE", got)
		}
	})

	t.Run("CHECK constraint rejects unknown phase", func(t *testing.T) {
		if _, err := conn.Exec(ctx,
			`UPDATE conversations SET care_phase = 'BOGUS' WHERE id = $1`, noRecs,
		); err == nil {
			t.Fatal("expected CHECK violation for unknown care_phase, got nil error")
		}
	})

	t.Run("NOT NULL enforced", func(t *testing.T) {
		if _, err := conn.Exec(ctx,
			`UPDATE conversations SET care_phase = NULL WHERE id = $1`, noRecs,
		); err == nil {
			t.Fatal("expected NOT NULL violation, got nil error")
		}
	})
}

// partialMigrationFS builds an in-memory fs.FS containing only the named
// migration files (read from the real migrations directory), so a test can
// drive migrate.Apply through an intermediate schema state instead of the
// full, latest one.
func partialMigrationFS(t *testing.T, names ...string) fstest.MapFS {
	t.Helper()
	dir := migrationsDir(t)
	out := fstest.MapFS{}
	for _, name := range names {
		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			t.Fatalf("read %s: %v", name, err)
		}
		out[name] = &fstest.MapFile{Data: body}
	}
	return out
}
