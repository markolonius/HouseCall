# Tasks: Cloud Platform MVP — End-to-End Vertical Slice

## Phase 1: Backend Module & Data Layer

### Task 1.1: Go module scaffold
- [x] Initialize `backend/go.mod` and the `cmd/server` + `internal/*` layout
- [x] Add the lightweight router (`chi`), `pgx`, and a WebSocket library
      (`coder/websocket`) as dependencies
- [x] `Makefile` targets: `run`, `test`, `migrate`, `seed` (seed is a
      placeholder pending Phase 7 Task 7.1)

### Task 1.2: PostgreSQL schema & migrations
- [x] Write migration files for `tenants`, `patients`, `physicians`,
      `care_relationships`, `conversations`, `messages`, `recommendations`,
      `audit_events` (`migrations/0001_init.sql`)
- [x] Every PHI-bearing table has a non-null `tenant_id`
- [x] `patients.state` (USPS code) and `physicians.states_licensed`
      (`text[]`) are non-null
- [x] `recommendations.state` constrained to the state-machine values
- [x] `recommendations.payload_type` constrained to
      (`guidance` | `prescription` | `lab_order` | `referral`),
      `recommendations.payload` is non-null JSONB
- [x] Cross-table FKs are composite on `(tenant_id, parent_id)` so the
      schema rejects rows whose parent belongs to a different tenant
      (defence-in-depth beyond the store-layer `WHERE tenant_id` reads)

### Task 1.3: Store layer with tenant scoping
- [x] `internal/store` access functions — each takes a `TenantID`; no
      query path omits it
- [x] Tests: a query for tenant A cannot read tenant B's rows
      (8 isolation tests covering patients, physicians, panels,
      conversations, messages, recommendations, audit events; 1
      schema-level test asserting cross-tenant parent inserts fail)

**Validation**: schema migrates cleanly (`make migrate` is idempotent);
9/9 tenant-scoping tests pass under `make test`; `make run` boots and
`/healthz` returns 200.

## Phase 2: Core API

### Task 2.1: Auth
- [ ] `POST /auth/login` — validate against `patients` / `physicians`, issue an
      HMAC-signed JWT
- [ ] JWT middleware — rejects missing/invalid/expired tokens; extracts
      `tenant_id` + actor identity into the request context

### Task 2.2: REST endpoints
- [ ] Conversations: list, create
- [ ] Messages: list, create (patient send)
- [ ] Recommendations: list (queue), get, review
- [ ] All handlers tenant-scoped via middleware context

### Task 2.3: WebSocket hub
- [ ] `/ws` with JWT-on-connect
- [ ] Push `recommendation.delivered` to patients, `queue.updated` to physicians

### Task 2.4: Audit writer
- [ ] `internal/audit` — writes `audit_events` with metadata only (no PHI)
- [ ] Wired into message ingestion, agent interaction, and every review action

**Validation**: authenticated REST + WebSocket round-trips work against the
compose stack; audit rows appear for each PHI-touching operation.

## Phase 3: Physician-in-Loop State Machine

### Task 3.1: State machine
- [ ] `internal/domain` — `Transition(current, action, actor)` pure function
- [ ] `DELIVERED` reachable only from `APPROVED` / `MODIFIED`
- [ ] The agent has no code path beyond `DRAFT` → `PENDING_REVIEW`

### Task 3.2: Enforcement & audit
- [ ] State change + `audit_event` written in one DB transaction
- [ ] Patient-visible content is set only on the `DELIVERED` transition

### Task 3.3: State-licensing enforcement
- [ ] `Transition` rejects any physician action when
      `physician.states_licensed` does not include the
      recommendation's `patient.state`
- [ ] The rejection emits an audit event and does not mutate state

### Task 3.4: Tests
- [ ] Exhaustive valid-transition tests
- [ ] Representative invalid-transition tests (each returns an error)
- [ ] Invariant test: `PENDING_REVIEW` / `REJECTED` content is never
      patient-visible
- [ ] State-licensing test: a physician unlicensed in the patient's state
      cannot approve, modify, or reject; the action is rejected and audited

**Validation**: `go test ./internal/domain/...` green; invariant and
state-licensing tests pass.

## Phase 4: AI Agent Runtime

### Task 4.1: Model client
- [ ] `internal/agent` — OpenAI-compatible HTTP client, configurable via
      `AGENT_MODEL_BASE_URL`
- [ ] Timeout + error handling; failures do not surface as clinical content

### Task 4.2: Reactive drafting
- [ ] On a persisted patient message: assemble tenant-scoped conversation
      context, call the model, create a `recommendation` in `DRAFT` with
      `payload_type = 'guidance'` and `payload = {"text": <model output>}`
- [ ] Immediately transition `DRAFT` → `PENDING_REVIEW`, write the audit event,
      emit `queue.updated`

### Task 4.3: Failure path
- [ ] Model endpoint unavailable → no recommendation created,
      `ai_interaction_failed` audit event written

**Validation**: a patient message produces a `PENDING_REVIEW` recommendation;
a forced model failure produces no recommendation and an audit event.

## Phase 5: Physician Web App

### Task 5.1: Auth & shell
- [ ] `internal/web` — login form, session cookie wrapping the JWT
- [ ] Base `html/template` layout

### Task 5.2: Panel & queue
- [ ] `GET /panel` — the physician's active care relationships
- [ ] `GET /queue` — `PENDING_REVIEW` recommendations for their patients only

### Task 5.3: Review actions
- [ ] `approve` / `reject` / `modify` (htmx) → Core API review endpoint
- [ ] `modify` allows editing `final_content` before delivery

**Validation**: a physician can log in, see only their patients' pending
recommendations, and drive each of the three actions.

## Phase 6: iOS Cloud Sync

### Task 6.1: Core Data migration
- [ ] Add `serverId` + `syncState` to `Conversation` and `Message`
      (lightweight migration)

### Task 6.2: Sync client
- [ ] New `SyncClient` — REST calls to the Core API using the JWT from
      `AuthenticationService`'s keychain session
- [ ] WebSocket listener for `recommendation.delivered`

### Task 6.3: Wire into the chat flow
- [ ] `AIConversationService` message send → `SyncClient` POST instead of a
      direct LLM provider call
- [ ] Delivered recommendation arrives via WebSocket → rendered as a generic
      `RecommendationCard` SwiftUI view in the conversation, keyed off
      `payload_type` so differentiated card types can be added later without
      reworking the chat
- [ ] Offline: messages stay `pending`, replay on reconnect

### Task 6.4: Tests
- [ ] `SyncClient` unit tests with a stubbed `URLProtocol`
- [ ] Full app build/run verified in Xcode (cannot build in the Linux image)

**Validation**: with the backend running, an iOS message produces a delivered,
physician-approved assistant reply; airplane-mode messages replay on reconnect.

## Phase 7: Local Dev Environment & End-to-End Test

### Task 7.1: Docker Compose
- [ ] `backend/docker-compose.yml` — `postgres` + `server`
- [ ] `make seed` — one tenant, one physician, one patient, one active care
      relationship

### Task 7.2: End-to-end test
- [ ] Scripted run against a real local model: seed → patient message via API →
      approve in the web app → assert delivery
- [ ] Document the local model setup (Ollama/vLLM + MedGemma variant)

**Validation**: `docker compose up` + local model + the e2e script proves the
full loop.

## Phase 8: Documentation

### Task 8.1: Backend README
- [ ] Replace the `backend/README.md` placeholder with real run instructions

### Task 8.2: Cross-references
- [ ] Note the MVP in `docs/PROJECT.md` (Phase 1 progress)
- [ ] Confirm `docs/ARCHITECTURE.md` §2/§4/§7 still match what was built;
      update if they drifted

**Validation**: a new developer can go from clone to a working loop using only
`backend/README.md`.
