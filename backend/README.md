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

### Prerequisites (managed for you)

Versions are pinned so you don't fight dependency drift:

- **Go** — pinned by [`../.tool-versions`](../.tool-versions) via `mise`, and
  by the `toolchain` directive in `go.mod`.
- **Postgres 16** — runs in Docker (`docker-compose.yml`), matching production
  (RDS Postgres 16). Not installed via brew, so a stray `brew upgrade` can't
  move it. The container runtime is **Colima** (no Docker Desktop required).
- **Xcode** — pinned by [`../.xcode-version`](../.xcode-version); install/select
  with `xcodes`. (Xcode cannot be containerized; it stays native — see
  [`../docs/WORKFLOW.md`](../docs/WORKFLOW.md).)
- **colima, docker CLI, docker-compose, gh, jq, mise, xcodes** — declared in
  [`../Brewfile`](../Brewfile).

### Mac mini quickstart (recommended)

From the repository root, run the one-shot bootstrap. It is idempotent: it
runs `brew bundle`, pins Go via `mise`, installs `beads`, starts the
Dockerized Postgres, applies migrations, wires up the beads graph, and runs
the environment doctor:

```bash
scripts/dev-bootstrap.sh
gh auth login          # if not already authenticated
scripts/doctor.sh      # green/red preflight; run before each session
```

Then drive development through the orchestrator from an interactive Claude
Code session (see [`../docs/WORKFLOW.md`](../docs/WORKFLOW.md)):

```
/run-phase add-cloud-platform-mvp 3
```

### Database commands

```bash
cd backend
make db-up      # start Postgres (Docker), wait until healthy
make db-down    # stop Postgres (data persists in the housecall-pgdata volume)
```

The `housecall` and `housecall_test` databases are created automatically on
first volume init (`docker/initdb/01-create-test-db.sql`).

### One-time setup (manual / Linux, without Docker)

If you are not on macOS, or prefer a host-native Postgres:

```bash
sudo -u postgres psql -c "CREATE USER housecall WITH PASSWORD 'housecall' SUPERUSER;"
sudo -u postgres psql -c "CREATE DATABASE housecall OWNER housecall;"
sudo -u postgres psql -c "CREATE DATABASE housecall_test OWNER housecall;"
```

### Common commands

```bash
make migrate    # apply pending SQL migrations
make run        # build and start the server on :8080
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

## Local AI model setup

The AI Agent Runtime calls an OpenAI-compatible chat-completions endpoint.
For local development the recommended path is **Ollama + medgemma:4b**.

### Install and start Ollama

```bash
# macOS (Homebrew)
brew install ollama

# Pull the model (one-time, ~3 GB download)
ollama pull medgemma:4b

# Start the Ollama server (if not already running as a service)
ollama serve          # listens on port 11434 by default
```

Verify the model is available:

```bash
ollama list           # should show medgemma:4b in the list
```

### How the compose stack reaches Ollama

`docker-compose.yml` sets:

```yaml
environment:
  AGENT_MODEL_BASE_URL: http://host.docker.internal:11434/v1
  AGENT_MODEL_NAME: medgemma:4b
extra_hosts:
  - "host.docker.internal:host-gateway"
```

`host.docker.internal` resolves automatically on Docker Desktop (macOS/Windows).
Under **Colima** (the default container runtime for this project), `extra_hosts`
maps the name to `host-gateway` so the container can reach the host's Ollama
process. No additional configuration is needed.

To use a different model, override `AGENT_MODEL_NAME`:

```bash
AGENT_MODEL_NAME=llama3.2 docker compose up -d --build --wait
```

### Alternative: vLLM with a MedGemma variant

For GPU-accelerated inference or the larger MedGemma variants, a
[vLLM](https://github.com/vllm-project/vllm) server with an
OpenAI-compatible endpoint works as a drop-in replacement:

```bash
# Example vLLM startup (requires a capable GPU)
vllm serve google/medgemma-27b-it --port 11434

# Point the compose stack at it
AGENT_MODEL_BASE_URL=http://host.docker.internal:11434/v1 \
AGENT_MODEL_NAME=google/medgemma-27b-it \
  docker compose up -d --build --wait
```

Any OpenAI-compatible `/v1/chat/completions` endpoint works — the agent
client negotiates the API contract, not the model name.

## End-to-end test

`scripts/e2e.sh` drives the complete physician-in-loop recommendation cycle
against a running local stack:

1. Patient logs in and posts a clinical question via the JSON API.
2. The agent drafts a recommendation and transitions it to `PENDING_REVIEW`.
3. Physician logs into the **web app** (`/web/login`) and approves the
   recommendation via the HTML review form (`POST /web/recommendations/{id}/review`).
4. Patient polls the JSON API until the recommendation state is `DELIVERED`
   with non-empty `final_content`.

### Prerequisites

- Ollama is running on the host: `ollama serve`
- `medgemma:4b` is downloaded: `ollama pull medgemma:4b`
- `curl` and `docker` are in `$PATH`
- `python3` is in `$PATH` (used for JSON parsing; `jq` is optional but recommended)

### One-command run

```bash
cd backend
./scripts/e2e.sh
```

The script calls `docker compose up -d --build --wait` and `make seed`
automatically, so a fresh clone only needs the prerequisites above.

If the stack is already up and seeded (e.g. you are iterating):

```bash
SKIP_UP=1 ./scripts/e2e.sh
```

### Expected output (abridged)

```
[e2e] ========================================
[e2e] HouseCall E2E Test
[e2e]   API:  http://localhost:8080
[e2e]   WEB:  http://localhost:8080
[e2e] ========================================
[e2e] Bringing up compose stack ...
[e2e] Seed complete.
[e2e] Step 1: patient login...
[e2e] Step 2: patient creates conversation...
[e2e] Step 3: patient posts message (triggers agent draft)...
[e2e] Step 4a: physician API login ...
[e2e] Step 5: polling physician queue for PENDING_REVIEW (timeout 120s)...
[e2e]   ...waiting for agent draft (0s elapsed, will retry in 3s)
[e2e] PENDING_REVIEW recommendation found: <uuid> (after 12s)
[e2e] Step 6: physician approves recommendation <uuid> via web app...
[e2e]   6a. Web app login...
[e2e]   Web login OK, hc_session cookie captured.
[e2e]   6b. Loading physician queue page...
[e2e]   Recommendation visible in queue.
[e2e]   6c. Submitting approve form...
[e2e]   Approve form submitted, redirected back to queue (HTTP 200).
[e2e] Step 7: patient polls for DELIVERED recommendation (timeout 30s)...
[e2e] Recommendation <uuid> is DELIVERED. final_content: [non-empty, content redacted]
[e2e] ========================================
[e2e] E2E PASSED
[e2e] Full loop verified:
[e2e]   patient message → agent draft → PENDING_REVIEW
[e2e]   physician approved via web app → DELIVERED
[e2e]   patient sees DELIVERED recommendation with non-empty content
[e2e] ========================================
```

### Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `API_BASE` | `http://localhost:8080` | JSON API base URL |
| `WEB_BASE` | `http://localhost:8080` | Web app base URL |
| `SKIP_UP` | `0` | Set `1` to skip `compose up` + seed |
| `AGENT_POLL_TIMEOUT` | `120` | Seconds to wait for PENDING_REVIEW |

### Colima / non-default port

The script auto-detects whether the server is reachable from the macOS host.
Under Colima with the macOS Virtualization.Framework, `localhost:8080` may not
be accessible from the host even though the container port is published. In
that case the script automatically falls back to running all HTTP calls via
`docker compose exec housecall-server wget ...` (exec mode). No manual
configuration is required.

To force exec mode explicitly (or if auto-detection is slow):

```bash
EXEC_MODE=exec ./scripts/e2e.sh
```

If the server is exposed on a different port:

```bash
API_BASE=http://localhost:9090 WEB_BASE=http://localhost:9090 ./scripts/e2e.sh
```

### Approve path: web app vs JSON API

The script drives the **web app** approve path
(`POST /web/recommendations/{id}/review` with a form-encoded `action=approve`
body and the `hc_session` cookie). This exercises the full server-rendered
physician UI path, not just the JSON API, which satisfies the task spec's
requirement to "approve in the web app". The JSON API review endpoint
(`POST /api/recommendations/{id}/review`) shares the same `review.Execute`
logic and is covered by the API integration tests.

### Model not yet downloaded

If `ollama list` does not show `medgemma:4b` when the patient message is
posted, the agent will fail to produce a recommendation and the script will
time out at step 5 with a clear diagnostic:

```
[e2e] FAIL: Timed out after 120s waiting for PENDING_REVIEW recommendation. Is the model running?
```

Pull the model and re-run:

```bash
ollama pull medgemma:4b
./scripts/e2e.sh
```

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
