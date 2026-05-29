package store

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/markolonius/housecall/backend/internal/migrate"
)

// testPool returns a pgxpool connected to TEST_DATABASE_URL with the
// migrations applied to a freshly truncated schema. Tests skip when the
// env var is unset so the suite compiles and runs without Postgres
// available.
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

	// Truncate every PHI-bearing table so the test starts from a clean
	// slate. Tenants is intentionally truncated too since most tests
	// create their own tenant rows.
	_, err = conn.Exec(ctx, `
		TRUNCATE
			audit_events,
			recommendations,
			messages,
			conversations,
			care_relationships,
			physicians,
			patients,
			tenants
		RESTART IDENTITY CASCADE`,
	)
	if err != nil {
		t.Fatalf("truncate: %v", err)
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
	return filepath.Join(filepath.Dir(file), "..", "..", "migrations")
}
