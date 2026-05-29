package migrate

import (
	"context"
	"fmt"
	"io/fs"
	"sort"
	"strings"

	"github.com/jackc/pgx/v5"
)

const schemaTable = `
CREATE TABLE IF NOT EXISTS schema_migrations (
    version     text PRIMARY KEY,
    applied_at  timestamptz NOT NULL DEFAULT now()
)`

// Apply applies every migration in dir that has not yet been recorded in
// schema_migrations. It returns the list of newly applied versions.
func Apply(ctx context.Context, conn *pgx.Conn, dir fs.FS) ([]string, error) {
	if _, err := conn.Exec(ctx, schemaTable); err != nil {
		return nil, fmt.Errorf("create schema_migrations: %w", err)
	}

	rows, err := conn.Query(ctx, `SELECT version FROM schema_migrations`)
	if err != nil {
		return nil, fmt.Errorf("read schema_migrations: %w", err)
	}
	applied := map[string]bool{}
	for rows.Next() {
		var v string
		if err := rows.Scan(&v); err != nil {
			rows.Close()
			return nil, err
		}
		applied[v] = true
	}
	rows.Close()

	entries, err := fs.ReadDir(dir, ".")
	if err != nil {
		return nil, fmt.Errorf("read migrations dir: %w", err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	var newly []string
	for _, name := range files {
		version := strings.TrimSuffix(name, ".sql")
		if applied[version] {
			continue
		}
		body, err := fs.ReadFile(dir, name)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", name, err)
		}
		if err := applyOne(ctx, conn, version, string(body)); err != nil {
			return nil, fmt.Errorf("apply %s: %w", name, err)
		}
		newly = append(newly, version)
	}
	return newly, nil
}

func applyOne(ctx context.Context, conn *pgx.Conn, version, body string) error {
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, body); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx,
		`INSERT INTO schema_migrations (version) VALUES ($1)`, version,
	); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
