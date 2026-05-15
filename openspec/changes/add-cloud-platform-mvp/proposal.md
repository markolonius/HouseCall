# Proposal: Cloud Platform MVP — End-to-End Vertical Slice

## Overview

Stand up the first working slice of the HouseCall cloud platform: a patient
sends a message from the iOS app, it reaches a new Go backend, the AI Agent
Runtime drafts a clinical recommendation in `PENDING_REVIEW`, a physician reviews
it in a minimal web app, and **only** an approved or modified recommendation is
delivered back to the patient. This proves the core physician-in-loop care loop
end to end while remaining runnable on a local developer machine — no AWS
dependency.

## Motivation

### Business Need
`docs/PROJECT.md`'s Phase 1 is large and blocked on the AWS BAA. The platform
needs an early, demonstrable proof that the core loop works — patient → AI draft
→ physician approval → patient delivery — to de-risk the architecture before
committing to the full Phase 1 build.

### User Value
- **Patients** get a clinically reviewed response, not a raw LLM output.
- **Physicians** get a working review queue with approve / reject / modify.

### Technical Drivers
- Validate the physician-in-loop state machine (`docs/ARCHITECTURE.md` §4) as
  real, enforced, audited code — not a diagram.
- Exercise the Go backend stack decision (ADR-001) and the local-model dev path
  (ADR-003).
- Establish the iOS ↔ cloud sync contract (`docs/ARCHITECTURE.md` §7).

## Proposed Changes

### New Capabilities
1. **`core-api`** — Go Core API service: a tenant-scoped data model (Tenant,
   Patient, Physician, CareRelationship, Conversation, Message, Recommendation,
   AuditEvent), REST + WebSocket endpoints, JWT authentication, PostgreSQL
   persistence.
2. **`physician-in-loop`** — the Recommendation lifecycle state machine and the
   architectural invariant that no AI output reaches a patient without a
   physician state transition.
3. **`ai-agent-runtime`** — a reactive agent that consumes a patient message,
   calls a local OpenAI-compatible model endpoint, and drafts a Recommendation
   in `PENDING_REVIEW`.
4. **`physician-web-app`** — a minimal web app: physician login, patient panel,
   and a recommendation review queue with approve / reject / modify.
5. **`ios-cloud-sync`** — an iOS sync layer: the existing chat routes messages
   through the Core API; local Core Data becomes an offline mirror with
   `serverId` + `syncState` tracking.

### Modified Capabilities
- The existing iOS message-send path (today: call an LLM provider directly)
  becomes a sync-through-the-Core-API path. This is captured additively in the
  `ios-cloud-sync` delta rather than as a rewrite of the existing iOS chat
  specs, because the existing on-device chat behaviour still exists underneath
  as the offline mirror.

## Impact Assessment

### User Impact
- Patients no longer receive unreviewed AI output — every response is
  physician-gated. Offline viewing of past conversations is preserved.
- Physicians gain a (minimal) clinical oversight surface that did not exist.

### Technical Impact
- New `backend/` Go module containing the Core API, the AI Agent Runtime, and
  the server-rendered physician web app.
- iOS: a lightweight Core Data migration adds `serverId` + `syncState` to
  `Conversation` and `Message`; a new sync client; `AIConversationService` is
  re-pointed from direct provider calls to the Core API.
- New local development environment (Docker Compose: PostgreSQL + Core API +
  Agent Runtime + physician web), plus a local OpenAI-compatible model server.

### Compliance Impact
- The physician-in-loop invariant becomes enforced code with exhaustive tests
  and an audit event on every state transition.
- **This MVP is explicitly local-development-only.** No real PHI, no AWS, no
  production traffic — so it does not itself require the AWS BAA, Zitadel, or
  production MedGemma. Those remain Phase 1 prerequisites for production.

## Alternatives Considered

### Alternative 1: Backend backbone only (no iOS, no web)
- **Pros**: smallest scope, fully verifiable locally.
- **Cons**: does not prove the loop — the whole point of the MVP.
- **Decision**: Rejected.

### Alternative 2: Full Phase 1
- **Pros**: production-ready.
- **Cons**: blocked on the AWS BAA; far too large for a first cut.
- **Decision**: Rejected.

### Alternative 3: Deterministic agent stub instead of a real model
- **Pros**: fully self-contained, no model dependency.
- **Cons**: does not exercise the real model integration.
- **Decision**: Rejected — the agent is wired to a local OpenAI-compatible
  endpoint per ADR-003's dev path.

### Alternative 4: Separate SPA for the physician web app
- **Pros**: closer to the eventual production stack.
- **Cons**: adds a JS build/toolchain to the MVP; harder to keep minimal.
- **Decision**: Deferred — the MVP physician web app is server-rendered Go
  (`html/template` + htmx), revisited when the production web stack is chosen.

## Success Criteria

### Functional Requirements
- ✅ A patient message sent from the iOS app reaches the Core API and persists.
- ✅ The agent drafts a Recommendation in `PENDING_REVIEW`; it is not visible to
  the patient.
- ✅ The physician sees it in the web queue; approve or modify → `DELIVERED`;
  reject → terminal.
- ✅ Only `APPROVED` and `MODIFIED` recommendations can reach the patient.
- ✅ The whole stack runs via `docker compose up` plus a local model server.

### Non-Functional Requirements
- Every PHI-bearing query is tenant-scoped; no cross-tenant read path exists.
- Every Recommendation state transition emits an `AuditEvent` with actor +
  decision.
- The iOS app remains usable offline (cached reads, queued writes).

### Quality Gates
- `go test ./...` green; the state machine has exhaustive valid/invalid
  transition tests.
- An explicit test asserts the "no patient delivery without a physician
  transition" invariant.
- `openspec validate add-cloud-platform-mvp --strict` passes.

## Timeline & Dependencies

### Prerequisites
- None external. The MVP runs locally; the AWS BAA, Zitadel, and production
  MedGemma are explicitly **not** prerequisites for this change.

### Dependencies
- Go (current stable), Docker + Docker Compose, and a local OpenAI-compatible
  model server (Ollama or vLLM).

### Estimated Effort
- 8 phases — see `tasks.md`.

### Phases
1. Backend module + data layer
2. Core API (auth, REST, WebSocket, audit)
3. Physician-in-loop state machine
4. AI Agent Runtime
5. Physician web app
6. iOS cloud sync
7. Local dev environment + end-to-end test
8. Documentation

## Open Questions
- **MVP auth**: the Core API issues its own JWT for the MVP, with Zitadel
  integration deferred to the next slice. Confirm this is acceptable as a
  local-only stopgap.
- **Local model**: which MedGemma variant (4B vs 27B text) should the dev
  environment standardize on, given local hardware constraints?
- **Physician web app stack**: the proposal recommends server-rendered Go for
  the MVP — confirm, or pull the production web-stack decision forward.

## Stakeholder Sign-off
- [ ] Engineering
- [ ] Clinical / physician-in-loop owner
- [ ] Compliance / HIPAA

---

**Change ID**: `add-cloud-platform-mvp`
**Status**: Proposed
**Created**: 2026-05-15
**Author**: HouseCall Team
