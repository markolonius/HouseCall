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
- [x] `POST /auth/login` — validate against `patients` / `physicians`, issue an
      HMAC-signed JWT (`internal/api/auth.go`; bcrypt comparison; opaque
      "invalid credentials" on any mismatch to prevent enumeration)
- [x] JWT middleware — rejects missing/invalid/expired tokens; extracts
      `tenant_id` + actor identity into the request context
      (`internal/api/jwt.go` stdlib HMAC-HS256; Cognito JWKS swap replaces
      `verifyToken` only — no domain or store changes)

### Task 2.2: REST endpoints
- [x] Conversations: list (patient only), create (patient only)
- [x] Messages: list, create (patient send; Phase 4 agent hook stubbed)
- [x] Recommendations: list queue (physician, scoped to their patients via
      `ListRecommendationsByPhysician`), get (patient sees only DELIVERED),
      review (approve/modify/reject via `domain.TransitionReview`)
- [x] All handlers tenant-scoped via `requireAuth` middleware context;
      actor-type guards enforce patient-vs-physician boundaries

### Task 2.3: WebSocket hub
- [x] `/ws` with JWT-on-connect (token in `?token=` query param for
      mobile clients that cannot set Upgrade headers)
- [x] `hub.SendToPatient` delivers `recommendation.delivered` on review
- [x] `hub.SendToPhysicians` ready for Phase 4 `queue.updated` push

### Task 2.4: Audit writer
- [x] `internal/audit.Writer` — writes `audit_events` with metadata only
      (no PHI); errors logged but not propagated so audit never blocks
      the clinical flow
- [x] Wired into: `auth.login`, `conversation.created`, `message.created`,
      `recommendation.reviewed` (the last two in a transaction via `store.Txn`)

**Note**: `internal/domain/recommendation.go` (Phase 3 Task 3.1) was
implemented here because `handleReviewRecommendation` requires
`TransitionReview`. Phase 3 adds state-licensing enforcement and exhaustive
tests.

**Validation**: authenticated REST + WebSocket round-trips work against the
compose stack; audit rows appear for each PHI-touching operation.

## Phase 3: Physician-in-Loop State Machine

### Task 3.1: State machine
- [x] `internal/domain` — `Transition(current, action, actor)` pure function
- [x] `DELIVERED` reachable only from `APPROVED` / `MODIFIED`
- [x] The agent has no code path beyond `DRAFT` → `PENDING_REVIEW`

### Task 3.2: Enforcement & audit
- [x] State change + `audit_event` written in one DB transaction
- [x] Patient-visible content is set only on the `DELIVERED` transition

### Task 3.3: State-licensing enforcement
- [x] `Transition` rejects any physician action when
      `physician.states_licensed` does not include the
      recommendation's `patient.state`
- [x] The rejection emits an audit event and does not mutate state

### Task 3.4: Tests
- [x] Exhaustive valid-transition tests
- [x] Representative invalid-transition tests (each returns an error)
- [x] Invariant test: `PENDING_REVIEW` / `REJECTED` content is never
      patient-visible
- [x] State-licensing test: a physician unlicensed in the patient's state
      cannot approve, modify, or reject; the action is rejected and audited

**Validation**: `go test ./internal/domain/...` green; invariant and
state-licensing tests pass.

## Phase 4: AI Agent Runtime

### Task 4.1: Model client
- [x] `internal/agent` — OpenAI-compatible HTTP client, configurable via
      `AGENT_MODEL_BASE_URL`
- [x] Timeout + error handling; failures do not surface as clinical content

### Task 4.2: Reactive drafting
- [x] On a persisted patient message: assemble tenant-scoped conversation
      context, call the model, create a `recommendation` in `DRAFT` with
      `payload_type = 'guidance'` and `payload = {"text": <model output>}`
- [x] Immediately transition `DRAFT` → `PENDING_REVIEW`, write the audit event,
      emit `queue.updated`

### Task 4.3: Failure path
- [x] Model endpoint unavailable → no recommendation created,
      `ai_interaction_failed` audit event written

**Validation**: a patient message produces a `PENDING_REVIEW` recommendation;
a forced model failure produces no recommendation and an audit event.

## Phase 5: Physician Web App

### Task 5.1: Auth & shell
- [x] `internal/web` — login form, session cookie wrapping the JWT
- [x] Base `html/template` layout

### Task 5.2: Panel & queue
- [x] `GET /panel` — the physician's active care relationships
- [x] `GET /queue` — `PENDING_REVIEW` recommendations for their patients only

### Task 5.3: Review actions
- [x] `approve` / `reject` / `modify` (htmx) → Core API review endpoint
- [x] `modify` allows editing `final_content` before delivery

**Validation**: a physician can log in, see only their patients' pending
recommendations, and drive each of the three actions.

## Phase 6: iOS Cloud Sync

### Task 6.1: Core Data migration
- [x] Add `serverId` + `syncState` to `Conversation` and `Message`
      (lightweight migration)

### Task 6.2: Sync client
- [x] New `SyncClient` — REST calls to the Core API using the JWT from
      `AuthenticationService`'s keychain session
- [x] WebSocket listener for `recommendation.delivered`

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
