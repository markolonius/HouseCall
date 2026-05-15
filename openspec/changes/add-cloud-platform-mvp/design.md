# Design: Cloud Platform MVP — End-to-End Vertical Slice

## Architecture Overview

```
┌──────────────────┐                    ┌─────────────────────┐
│  Patient iOS App │                    │  Physician Web App  │
│  (SwiftUI)       │                    │  (server-rendered   │
│  + sync layer    │                    │   Go: html/template │
└────────┬─────────┘                    │   + htmx)           │
         │ REST + WebSocket             └──────────┬──────────┘
         │ (JWT)                                   │ HTTP (JWT, session cookie)
         └───────────────┬─────────────────────────┘
                         │
                ┌────────▼─────────┐
                │   Core API       │  Go service: auth, REST, WebSocket,
                │   (Go)           │  tenant scoping, recommendation
                │                  │  state machine, audit
                └───┬──────────┬───┘
                    │          │ in-process call / channel
                    │   ┌──────▼───────────┐
                    │   │ AI Agent Runtime │  drafts recommendations;
                    │   │ (Go)             │  calls local model
                    │   └──────┬───────────┘
                    │          │ HTTP (OpenAI-compatible)
                    │   ┌──────▼───────────┐
                    │   │ Local model      │  Ollama / vLLM serving
                    │   │ server           │  MedGemma (dev)
                    │   └──────────────────┘
            ┌───────▼────────┐
            │  PostgreSQL    │  system of record; every PHI row tenant-scoped
            └────────────────┘
```

For the MVP the Core API and the AI Agent Runtime ship as **one Go binary with
two packages** (invoked in-process), not two deployable services. This keeps the
MVP runnable and testable; `docs/ARCHITECTURE.md` §2 still treats them as
logically separate components, and the package boundary is kept clean so they
can be split later.

## Component Design

### 1. Repository Layout

```
backend/
  go.mod
  cmd/
    server/            # main(): wires Core API + Agent + physician web
  internal/
    api/               # REST handlers, WebSocket hub, middleware (auth, tenant)
    domain/            # entities, the Recommendation state machine
    store/             # PostgreSQL access (pgx), migrations
    agent/             # AI Agent Runtime: context assembly, model client
    web/               # physician web app: html/template views, htmx handlers
    audit/             # AuditEvent writer
  migrations/          # SQL migration files
  docker-compose.yml   # postgres + server (model server is external/optional)
  Makefile
```

Minimal / assemble-libraries per ADR-001: stdlib `net/http` + a lightweight
router, `pgx` for PostgreSQL, a maintained WebSocket library, `html/template`
for the web app. No heavyweight framework.

### 2. Data Model (PostgreSQL)

Every PHI-bearing table carries `tenant_id`. MVP entities (a subset of
`docs/ARCHITECTURE.md` §4):

| Table | Key fields |
|---|---|
| `tenants` | `id`, `kind` (`dtc` for the MVP), `name` |
| `patients` | `id`, `tenant_id`, `email`, `full_name`, `created_at` |
| `physicians` | `id`, `tenant_id`, `email`, `full_name`, `states_licensed` |
| `care_relationships` | `id`, `tenant_id`, `patient_id`, `physician_id`, `active` |
| `conversations` | `id`, `tenant_id`, `patient_id`, `title`, `created_at`, `updated_at` |
| `messages` | `id`, `tenant_id`, `conversation_id`, `role`, `content`, `created_at` |
| `recommendations` | `id`, `tenant_id`, `conversation_id`, `patient_id`, `state`, `draft_content`, `final_content`, `created_at`, `reviewed_by`, `reviewed_at` |
| `audit_events` | `id`, `tenant_id`, `actor_type`, `actor_id`, `event_type`, `metadata` (JSONB, no PHI), `created_at` |

Tenant scoping is enforced in the `store` layer: every query takes a
`tenant_id` and there is no query path that omits it. (PostgreSQL row-level
security is the production mechanism per §4; for the MVP, store-layer
enforcement plus tests is sufficient and simpler.)

### 3. Physician-in-Loop State Machine (`internal/domain`)

```
DRAFT ──► PENDING_REVIEW ──► APPROVED  ──► DELIVERED
                          ├► MODIFIED  ──► DELIVERED
                          └► REJECTED  (terminal)
```

- The state machine is a single pure function `Transition(current, action,
  actor) (next State, error)`. Invalid transitions return an error; they are
  never silently ignored.
- `DELIVERED` is reachable **only** from `APPROVED` or `MODIFIED`, and the
  transition into `DELIVERED` is the only code path that sets
  `final_content` visible to the patient.
- Every successful transition writes an `audit_event` (`event_type`,
  `actor_id`, the decision) in the same DB transaction as the state change.
- The agent can only ever create a recommendation in `DRAFT` and move it to
  `PENDING_REVIEW`. It has no code path to `APPROVED`/`MODIFIED`/`DELIVERED`.

### 4. Core API Surface

REST (all under `/api`, all require a valid JWT, all tenant-scoped):

| Method + path | Purpose |
|---|---|
| `POST /auth/login` | Patient or physician login → JWT |
| `GET /conversations` | List the caller's conversations |
| `POST /conversations` | Create a conversation |
| `GET /conversations/{id}/messages` | List messages |
| `POST /conversations/{id}/messages` | Patient sends a message → triggers the agent |
| `GET /recommendations?state=PENDING_REVIEW` | Physician review queue |
| `POST /recommendations/{id}/review` | Physician action: approve / reject / modify |
| `GET /recommendations/{id}` | Fetch a recommendation (patient sees it only once `DELIVERED`) |

WebSocket `/ws` (JWT on connect): pushes `recommendation.delivered` to the
patient and `queue.updated` to the physician.

### 5. AI Agent Runtime (`internal/agent`)

- Triggered in-process when `POST /conversations/{id}/messages` persists a
  patient message.
- Assembles context: the conversation's message history (tenant-scoped) plus a
  system prompt. (Protocols from §4 are out of scope for the MVP.)
- Calls a configurable OpenAI-compatible endpoint
  (`AGENT_MODEL_BASE_URL`, default `http://localhost:11434/v1`) — the same
  OpenAI-compatible shape the iOS `CustomProvider` already uses, so the request
  format is well understood.
- On success: creates a `recommendation` row in `DRAFT`, immediately transitions
  it to `PENDING_REVIEW`, writes the audit event, emits `queue.updated`.
- On model-endpoint failure: no recommendation is created; an
  `ai_interaction_failed` audit event is written; the patient is not shown an
  error masquerading as a clinical response.

### 6. Physician Web App (`internal/web`)

Server-rendered Go (`html/template` + htmx for the queue actions). Routes:

| Route | Purpose |
|---|---|
| `GET /` → `/login` | Physician login form |
| `POST /login` | Session cookie (wraps the same JWT) |
| `GET /panel` | Patient panel — the physician's active care relationships |
| `GET /queue` | `PENDING_REVIEW` recommendations for the physician's patients |
| `POST /queue/{id}/approve|reject|modify` | Calls the Core API review endpoint |

No separate JS build. The whole web app is compiled into the server binary.

### 7. iOS Cloud Sync (`ios-cloud-sync`)

Core Data migration (lightweight): add `serverId: String?` and
`syncState: String?` (`local` / `pending` / `synced` / `failed`) to
`Conversation` and `Message`.

Message-send flow change in `AIConversationService`:
1. User message saved locally (`syncState = pending`) — unchanged persistence.
2. **New**: `SyncClient` POSTs the message to `POST /conversations/{id}/messages`
   with the JWT from `AuthenticationService`'s keychain-held session.
3. On success: local message gets its `serverId`, `syncState = synced`.
4. The AI response is **not** streamed back inline anymore. Instead the app
   listens on the WebSocket (or polls) for `recommendation.delivered` and then
   shows the delivered content as the assistant message.
5. Offline: step 2 fails → message stays `pending`; a replay pass retries on
   reconnect.

Reuse: `AuthenticationService` already keychain-manages a session token
(`UserSession.sessionToken`) — the MVP stores the Core API JWT there. The
existing `CustomProvider` OpenAI-compatible client is **not** used to reach the
Core API (the Core API is not an LLM endpoint); a small dedicated `SyncClient`
is added instead. The agent-to-model OpenAI-compatible call lives server-side.

### 8. Authentication (MVP)

**Decision:** the Core API issues its own short-lived JWT (HMAC-signed) from
`POST /auth/login`, validated against the `patients` / `physicians` tables.
Zitadel (ADR-002) is **deferred to the next slice** — wiring full OIDC
federation is disproportionate for a local-only MVP.
**Rationale:** keeps the MVP self-contained and runnable with `docker compose
up`; the JWT middleware boundary is the same one Zitadel-issued tokens will plug
into later, so this is a stopgap at the edge, not a throwaway core.
**Risk:** the MVP login is not production auth — mitigated by the MVP being
local-development-only and by isolating all token logic behind one middleware.

### 9. Local Development Environment

`backend/docker-compose.yml`: `postgres` + `server` (Core API + Agent + web in
one binary). The model server runs outside compose (Ollama/vLLM on the host or
a separate container), pointed at via `AGENT_MODEL_BASE_URL`. A `Makefile`
target runs migrations and seeds one tenant, one physician, one patient, and an
active care relationship so the loop is demoable immediately.

## Testing Strategy

- **Unit** ✅ — the state machine `Transition` function: every valid transition
  and a representative set of invalid ones; the tenant-scoping store helpers.
- **Integration** ✅ — against a real PostgreSQL (compose): message ingestion →
  agent draft → review → delivery, with the agent's model call faked at the
  HTTP boundary.
- **Invariant** ✅ — an explicit test asserting a `PENDING_REVIEW` or `REJECTED`
  recommendation is never returned as patient-visible content, and that the
  agent has no path to `DELIVERED`.
- **End-to-end** ✅ — a scripted run with a real local model: seed data → drive a
  patient message via the API → approve in the web app → assert delivery.
- **iOS** ⚠️ — sync client unit tests with a stubbed `URLProtocol`; the full app
  build/run is verified in Xcode (cannot be built in the Linux CI/dev image).

## Deployment Considerations

- **Non-goals (explicitly deferred):** AWS infrastructure, Zitadel, production
  MedGemma hosting, HealthKit ingestion, the proactive monitoring loop,
  escalation/triage, practice/health-system tenancy, billing, voice/multimodal.
- **No real PHI** touches this MVP — seed data only.
- **Migration path:** the Core API JWT middleware and the `backend/` package
  boundaries are designed so the next slice can (a) replace MVP login with
  Zitadel OIDC and (b) split the Agent Runtime into its own service without
  reworking the domain or store layers.
