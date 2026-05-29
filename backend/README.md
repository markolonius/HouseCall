# HouseCall Backend

Go services for the HouseCall platform — Core API, AI Agent Runtime, and the
server-rendered physician web app (see [`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md) §2).
For the MVP the three components ship as one Go binary with package
boundaries kept clean so the Agent Runtime can be split out later without
reworking the domain or store layers.

**Status:** Phase 1 of `add-cloud-platform-mvp` is complete — Go module
scaffold, PostgreSQL schema, tenant-scoped store, tenant-isolation tests,
and a runnable `cmd/server` binary with `/healthz`. Phases 2–8
(REST + WebSocket, the physician-in-loop state machine, the AI Agent
Runtime, the physician web app, iOS sync, Docker Compose, e2e) are not
yet implemented.

## Layout

```
backend/
  cmd/server/        main(): migrate or serve subcommands
  internal/
    migrate/         tiny SQL migration runner backed by schema_migrations
    store/           pgx store; every PHI query takes a TenantID
  migrations/        0001_init.sql and forward
  Makefile           build, run, test, migrate
  go.mod
```

## Dependencies

- `github.com/jackc/pgx/v5` — PostgreSQL driver and connection pool
- `github.com/go-chi/chi/v5` — HTTP router
- `github.com/coder/websocket` — WebSocket library (used from Phase 2.3)
- `github.com/google/uuid` — UUID type
- Standard library otherwise. No web framework; no ORM.

## Local development

### Prerequisites

- Go 1.25 or newer (the toolchain auto-upgrades when needed).
- PostgreSQL 15 or newer, reachable on `localhost:5432`.

### One-time setup

```bash
sudo -u postgres psql -c "CREATE USER housecall WITH PASSWORD 'housecall' SUPERUSER;"
sudo -u postgres psql -c "CREATE DATABASE housecall OWNER housecall;"
sudo -u postgres psql -c "CREATE DATABASE housecall_test OWNER housecall;"
```

`docker-compose.yml` is on the Phase 7 task list and will replace this manual
step. Until then, a local Postgres works fine.

### Common commands

```bash
make migrate    # apply pending SQL migrations
make run        # build and start the server on :8080 (currently serves /healthz only)
make test       # run the test suite against $TEST_DATABASE_URL
make tidy       # go mod tidy
```

Override the connection string when needed:

```bash
make migrate DATABASE_URL=postgres://user:pass@host:port/db?sslmode=disable
make test    TEST_DATABASE_URL=postgres://user:pass@host:port/test_db?sslmode=disable
```

Tests that depend on PostgreSQL skip cleanly when `TEST_DATABASE_URL` is
unset, so `go test ./...` always compiles and runs (pure-Go tests still
execute; DB-bound tests skip).

## Data model

See [`../openspec/changes/add-cloud-platform-mvp/design.md`](../openspec/changes/add-cloud-platform-mvp/design.md) §2 for the
table list and rationale. Highlights:

- Every PHI-bearing table carries a non-null `tenant_id`.
- Cross-table foreign keys are **composite** on `(tenant_id, parent_id)`
  so the schema itself rejects rows whose parent belongs to a different
  tenant. The store layer also includes `tenant_id` in every `WHERE`
  clause; the composite FK is defence-in-depth.
- `recommendations.payload_type` is constrained to
  `{guidance, prescription, lab_order, referral}`. Phase 4 only writes
  `guidance`; the prescribing and lab-order payload types are produced by
  `add-pa-chronic-disease-launch`.

## Migrations

`internal/migrate` is a small SQL runner: files in `migrations/` named
`NNNN_<description>.sql` are applied in lexicographic order, tracked in
`schema_migrations`. There is no down-migration path on purpose — schema
rollback at MVP scale is handled by restoring a snapshot.

To add a migration: drop a new `NNNN_<description>.sql` into
`migrations/` with the next number and run `make migrate`.

## Tests

`internal/store` ships a tenant-isolation suite that:

1. Creates two parallel tenants with patients, physicians, care
   relationships, conversations, messages, and recommendations.
2. Asserts every read function returns `ErrNotFound` (or an empty list)
   when called with the wrong tenant id.
3. Asserts the schema's composite FKs reject a cross-tenant parent at
   write time.

Run the suite with `make test`. The Phase 2 work will extend it with
authenticated REST round-trips and the audit-event invariant.
