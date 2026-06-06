# HouseCall Backend

The Go Core API, AI Agent Runtime, and server-rendered physician web app for the
HouseCall cloud platform MVP. All three components ship as one binary with clean
package boundaries so the Agent Runtime can be extracted later without reworking
the domain or store layers.

For the overall system design — tenancy model, PHI data flow, state machine, and
how this backend fits with the iOS app — see
[`../docs/ARCHITECTURE.md`](../docs/ARCHITECTURE.md).

---

## Prerequisites

| Tool | Required? | Notes |
|---|---|---|
| **Go 1.25+** | Yes | Pinned in `go.mod`; use `mise` or install directly |
| **Docker** | Yes | Colima works; Docker Desktop works |
| **`docker compose`** (v2) | Yes | Bundled with Docker Desktop; `brew install docker-compose` for Colima |
| **Ollama** | For AI path | The AI Agent calls a local model at `localhost:11434` |
| `curl`, `python3` or `jq` | For e2e test | Standard on macOS; used by `scripts/e2e.sh` |

Go must be at least 1.25 (`go.mod` declares `go 1.25.0`). Check with:

```bash
go version
```

---

## Quick start

The shortest path from clone to a running, seeded stack with the e2e passing.

### 1. Copy the environment file

```bash
cd backend
cp .env.example .env
# .env is gitignored; the defaults work for local dev
```

### 2. Pull the AI model (one-time, ~3 GB)

```bash
brew install ollama          # macOS — skip if already installed
ollama pull medgemma:4b
ollama serve                 # keep this running in a terminal tab
```

### 3. Bring up the stack and seed it

```bash
make compose-up
```

This single target:
1. Runs `docker compose up -d --build --wait` — builds the Go binary inside the
   container, starts Postgres 16 and the server, waits until both are healthy.
2. Runs `make seed` — inserts one synthetic tenant, physician, patient, and care
   relationship (idempotent, safe to re-run).

Verify the server is healthy:

```bash
curl http://localhost:8080/healthz
# → ok
```

### 4. Run the end-to-end test

```bash
./scripts/e2e.sh
```

Expected tail of output:

```
[e2e] ========================================
[e2e] E2E PASSED
[e2e] Full loop verified:
[e2e]   patient message → agent draft → PENDING_REVIEW
[e2e]   physician approved via web app → DELIVERED
[e2e]   patient sees DELIVERED recommendation with non-empty content
[e2e] ========================================
```

---

## Configuration

### Environment variables

The server binary reads these from the process environment (or the `.env` file
when running via `docker compose`).

| Variable | Required | Default (dev) | Description |
|---|---|---|---|
| `DATABASE_URL` | **Yes** | — | PostgreSQL DSN (`postgres://user:pass@host:port/db?sslmode=disable`) |
| `JWT_SECRET` | **Yes** | — | HMAC-HS256 signing secret; must be ≥ 16 characters |
| `AGENT_MODEL_BASE_URL` | No | `http://host.docker.internal:11434/v1` | OpenAI-compatible chat completions base URL |
| `AGENT_MODEL_NAME` | No | `medgemma:4b` | Model identifier passed in the `model` field |
| `AGENT_MODEL_API_KEY` | No | _(empty)_ | Bearer token for hosted endpoints; leave empty for Ollama |

The Makefile supplies dev defaults:

```
DATABASE_URL      = postgres://housecall:housecall@localhost:5432/housecall?sslmode=disable
TEST_DATABASE_URL = postgres://housecall:housecall@localhost:5432/housecall_test?sslmode=disable
JWT_SECRET        = dev-secret-change-me-in-production
```

> **Never use `sslmode=disable` outside localhost. Never commit a real `JWT_SECRET`.**
> Generate a strong one: `openssl rand -hex 32`.

### Compose-managed values

`docker-compose.yml` sets these automatically for the `server` container:

```yaml
DATABASE_URL:         postgres://housecall:housecall@postgres:5432/housecall?sslmode=disable
JWT_SECRET:           ${JWT_SECRET:-dev-jwt-secret-change-me-in-production}
AGENT_MODEL_BASE_URL: http://host.docker.internal:11434/v1
AGENT_MODEL_NAME:     ${AGENT_MODEL_NAME:-medgemma:4b}
AGENT_MODEL_API_KEY:  ${AGENT_MODEL_API_KEY:-}
SERVER_PORT:          ${SERVER_PORT:-8080}   # host-side port binding
```

Override `JWT_SECRET` for any non-localhost environment by setting it in your
shell before running compose:

```bash
export JWT_SECRET="$(openssl rand -hex 32)"
make compose-up
```

### Colima and `host.docker.internal`

`host.docker.internal` resolves automatically on Docker Desktop (macOS/Windows).
Under **Colima** the daemon does not inject this hostname; `docker-compose.yml`
includes an `extra_hosts` entry that maps it to `host-gateway` so the container
can reach the host's Ollama process. No manual configuration is required.

### Local AI model setup

The Agent Runtime requires an OpenAI-compatible `/v1/chat/completions` endpoint.

**Recommended: Ollama + medgemma:4b**

```bash
brew install ollama
ollama pull medgemma:4b      # one-time download, ~3 GB
ollama serve                 # listens on port 11434 by default
ollama list                  # verify medgemma:4b appears
```

To use a different model, set `AGENT_MODEL_NAME` before bringing up the stack:

```bash
AGENT_MODEL_NAME=llama3.2 make compose-up
```

**Alternative: vLLM (GPU)**

```bash
vllm serve google/medgemma-27b-it --port 11434

AGENT_MODEL_BASE_URL=http://host.docker.internal:11434/v1 \
AGENT_MODEL_NAME=google/medgemma-27b-it \
  docker compose up -d --build --wait
```

Any endpoint that implements `POST /v1/chat/completions` (OpenAI-compatible) is
a valid drop-in.

---

## Local development without Docker

Use this path when you want fast rebuild-test cycles or prefer a host-native
Postgres.

### Start Postgres

Either run the compose Postgres service alone:

```bash
cd backend
make db-up      # docker compose up -d --wait postgres
```

Or create a host-native database:

```bash
sudo -u postgres psql -c "CREATE USER housecall WITH PASSWORD 'housecall' SUPERUSER;"
sudo -u postgres psql -c "CREATE DATABASE housecall OWNER housecall;"
sudo -u postgres psql -c "CREATE DATABASE housecall_test OWNER housecall;"
```

### Apply migrations and start the server

```bash
make migrate    # applies pending SQL files from migrations/
make seed       # inserts synthetic seed data (idempotent)
make run        # build + start the server on :8080
```

Override the DSN for a non-default Postgres:

```bash
make migrate DATABASE_URL=postgres://user:pass@host:port/db?sslmode=disable
make run     DATABASE_URL=postgres://user:pass@host:port/db?sslmode=disable JWT_SECRET=my-secret
```

### Stop Postgres

```bash
make db-down    # docker compose down (data persists in housecall-pgdata volume)
```

---

## Running tests

```bash
make test
```

This runs `go test ./...` with `TEST_DATABASE_URL` set. Tests that require
PostgreSQL skip cleanly when `TEST_DATABASE_URL` is unset, so the suite always
compiles and pure-Go tests still execute.

Override the test DSN:

```bash
make test TEST_DATABASE_URL=postgres://user:pass@host:port/housecall_test?sslmode=disable
```

Run a specific package or test:

```bash
cd backend
TEST_DATABASE_URL=postgres://housecall:housecall@localhost:5432/housecall_test?sslmode=disable \
  go test ./internal/store/... -run TestTenantIsolation -v
```

The `internal/store` suite includes a tenant-isolation battery:
1. Creates two parallel tenants with patients, physicians, care relationships,
   conversations, messages, and recommendations.
2. Asserts every read function returns `ErrNotFound` (or an empty list) when
   called with the wrong tenant id.
3. Asserts the schema's composite foreign keys reject cross-tenant parent rows
   at write time.

---

## End-to-end test

`scripts/e2e.sh` drives the complete physician-in-loop recommendation cycle
against a running local stack.

### What it verifies

1. Patient logs in and posts a clinical question via the JSON API.
2. The agent drafts a recommendation and transitions it to `PENDING_REVIEW`.
3. Physician logs into the web app (`/web/login`) and approves the
   recommendation via the HTML review form
   (`POST /web/recommendations/{id}/review` with `action=approve`).
4. Patient polls the JSON API until the recommendation is `DELIVERED` with
   non-empty `final_content`.

### Prerequisites

- Ollama is running: `ollama serve`
- Model is downloaded: `ollama pull medgemma:4b`
- `curl` and `docker` are in `$PATH`
- `python3` or `jq` is in `$PATH` (for JSON parsing)

### Running

From the `backend/` directory:

```bash
./scripts/e2e.sh
```

The script calls `docker compose up -d --build --wait` and `make seed`
automatically. A fresh clone only needs the prerequisites above.

If the stack is already up and seeded (e.g. iterating on a fix):

```bash
SKIP_UP=1 ./scripts/e2e.sh
```

### Environment overrides

| Variable | Default | Purpose |
|---|---|---|
| `API_BASE` | `http://localhost:8080` | JSON API base URL |
| `WEB_BASE` | `http://localhost:8080` | Web app base URL |
| `SKIP_UP` | `0` | Set `1` to skip `compose up` and seed |
| `AGENT_POLL_TIMEOUT` | `120` | Seconds to wait for `PENDING_REVIEW` |
| `EXEC_MODE` | _(auto)_ | Force `host` (curl) or `exec` (docker exec wget) |

### Colima / exec mode

The script auto-detects whether `localhost:8080` is reachable from the macOS
host. Under Colima with the macOS Virtualization.Framework, host-to-container
port forwarding may not work even though the port is published. When the
auto-detection probe fails, the script falls back to running all HTTP calls via
`docker compose exec housecall-server wget ...` inside the container — the
server binary is exercised identically either way.

To force exec mode explicitly:

```bash
EXEC_MODE=exec ./scripts/e2e.sh
```

For a non-default port:

```bash
API_BASE=http://localhost:9090 WEB_BASE=http://localhost:9090 ./scripts/e2e.sh
```

---

## Project layout

```
backend/
├── cmd/
│   ├── server/        main(): -cmd serve|migrate; listens on :8080
│   └── seed/          inserts synthetic dev data (tenant + physician + patient)
├── internal/
│   ├── agent/         AI Agent Runtime — Drafter, LLM client (OpenAI-compat)
│   ├── api/           JSON REST API router (chi); auth, conversations, messages,
│   │                  recommendations endpoints
│   ├── audit/         Audit event writer; logs to the audit_events table
│   ├── domain/        Shared domain types (Recommendation states, etc.)
│   ├── jwtutil/       JWT sign/verify helpers (HMAC-HS256)
│   ├── migrate/       Lightweight SQL migration runner (schema_migrations table)
│   ├── review/        Physician review business logic shared by API + web
│   ├── store/         pgx store; every PHI query takes a TenantID
│   └── web/           Server-rendered physician web app (chi + html/template)
│       └── templates/ HTML templates for login, queue, and review pages
├── migrations/        SQL migration files (NNNN_<description>.sql)
├── docker/
│   └── initdb/        01-create-test-db.sql — creates housecall_test on first run
├── scripts/
│   └── e2e.sh         End-to-end test driver
├── Dockerfile
├── Makefile
├── docker-compose.yml
├── .env.example
└── go.mod
```

### Schema highlights

- Every PHI-bearing table carries a non-null `tenant_id`.
- Cross-table foreign keys are composite on `(tenant_id, parent_id)` so the
  schema rejects rows whose parent belongs to a different tenant. The store
  layer also filters by `tenant_id` in every `WHERE` clause — defence in depth.
- `recommendations.payload_type` is constrained to
  `{guidance, prescription, lab_order, referral}`. The MVP writes `guidance`;
  other types are added by later change proposals.

### Migrations

SQL files in `migrations/` named `NNNN_<description>.sql` are applied in
lexicographic order and tracked in `schema_migrations`. There is no down-migration
path — schema rollback at MVP scale is handled by restoring a volume snapshot.

To add a migration: create the next-numbered file and run `make migrate`.

---

## Seed credentials (dev-only, synthetic, non-PHI)

`make seed` (or `make compose-up`) inserts deterministic rows that the e2e
script relies on. Re-running is safe (all inserts use `ON CONFLICT DO NOTHING`).

| Role | Email | Password |
|---|---|---|
| Physician | `physician@dev.housecall.local` | `PhysicianDev1!` |
| Patient | `patient@dev.housecall.local` | `PatientDev1!` |

Tenant id: `00000000-0000-0000-0000-000000000001`

---

## Troubleshooting

### e2e times out at step 5 ("waiting for PENDING_REVIEW")

The agent could not reach the model. Steps:

1. `ollama serve` — ensure Ollama is running on the host.
2. `ollama list` — confirm `medgemma:4b` (or your chosen model) appears.
3. `ollama pull medgemma:4b` — download it if missing.
4. `docker compose logs server | tail -50` — check for connection errors.

Under Colima: the `extra_hosts` entry in `docker-compose.yml` should make
`host.docker.internal` resolve inside the container. If not:

```bash
docker exec housecall-server wget -qO- http://host.docker.internal:11434/api/tags
```

If that fails, Colima's `host-gateway` may not be set up. Try restarting Colima:
`colima stop && colima start`.

### Port 5432 already in use

A local Postgres is running. Either stop it (`brew services stop postgresql@16`)
or change the compose port mapping in `docker-compose.yml`.

### `JWT_SECRET must be set and at least 16 characters`

The server enforces this at startup. Set `JWT_SECRET` in your shell or `.env`
file before running `make run` or `docker compose up`.

### `localhost:8080` not reachable under Colima

Use exec mode for the e2e test (`EXEC_MODE=exec ./scripts/e2e.sh`) and verify
Colima's network mode. Colima with `--network-address` or `vmType: vz` mode
(macOS Virtualization.Framework) may not forward published ports to the host.
Switching to `vmType: qemu` resolves this in most cases.

### `go: toolchain go1.25.0 is not available`

Install Go 1.25+ from <https://go.dev/dl/> or via `mise`:

```bash
mise use go@1.25
```
