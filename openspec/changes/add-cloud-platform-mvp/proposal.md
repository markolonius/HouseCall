# Proposal: Cloud Platform MVP — End-to-End Vertical Slice

## Overview

Stand up the first working slice of the HouseCall cloud platform: a patient
sends a message from the iOS app, it reaches a new Go backend, the AI Agent
Runtime drafts a clinical recommendation in `PENDING_REVIEW`, a physician reviews
it in a minimal web app, and **only** an approved or modified recommendation is
delivered back to the patient. This proves the core physician-in-loop care loop
end to end while remaining runnable on a local developer machine — no AWS
dependency.

The MVP loop produces `guidance`-typed recommendations only, but the data model
is designed forward-compatible with the prescribing-practice payload types
(`prescription`, `lab_order`, `referral`) that the production practice will
require. Live prescribing, e-prescribe integration, and lab-order routing are
explicitly out of scope for this slice.

## Strategic Context

This MVP is the first technical slice of a larger product strategy. The
following strategic decisions are now locked and shape the design below; they
are recorded here so the MVP's data model, governance, and deployment target
match where the platform is headed.

- **Clinical scope**: full primary care practice (head-to-head with Lotus).
  Prescriptions, lab orders, and referrals are first-class concepts in the
  data model.
- **Beachhead**: chronic disease management (diabetes, hypertension, etc.),
  launched in a single state to keep the medical-board surface manageable for
  a solo founder.
- **Legal entity**: Public Benefit Corporation. The charter's public-benefit
  purpose forbids monetizing PHI; this is an architectural invariant, not a
  policy preference.
- **Pricing**: $29–$49/month subscription. Drives a discipline around
  high-leverage physician panels (AI assist enabling ~700–1,000
  patients/physician for chronic care) rather than a traditional ~400-patient
  DPC panel.
- **Production hosting**: AWS direct with a Business Associate Agreement. Only
  AWS HIPAA-eligible services. The MVP itself remains local-only; the
  production target is captured in `design.md` so the package boundaries do
  not paint into a corner.
- **iOS UX direction**: chat-first with inline action cards. The MVP renders a
  generic recommendation card; differentiated card types (prescription, lab,
  referral) ship post-MVP.
- **Team**: solo founder. Out-of-scope work — clinician console SPA,
  prescribing integrations, multi-state expansion, production hosting — is
  deferred so the MVP stays shippable by one person.

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
   Patient, Physician, CareRelationship, Conversation, Message, Recommendation
   with a `payload_type`-discriminated payload, AuditEvent), REST + WebSocket
   endpoints, JWT authentication, PostgreSQL persistence. Patients carry a
   `state` field and physicians a `states_licensed` set so the
   state-licensing invariant can be enforced from day one.
2. **`physician-in-loop`** — the Recommendation lifecycle state machine, the
   architectural invariant that no AI output reaches a patient without a
   physician state transition, and the state-licensing invariant that a
   physician can only act on a patient resident in a state the physician is
   licensed in.
3. **`ai-agent-runtime`** — a reactive agent that consumes a patient message,
   calls a local OpenAI-compatible model endpoint, and drafts a Recommendation
   with `payload_type = guidance` in `PENDING_REVIEW`. Differentiated payload
   types (prescription, lab order, referral) are out of scope for the MVP but
   the runtime is structured so they can be added without changing the loop.
4. **`physician-web-app`** — a minimal web app: physician login, patient panel,
   and a recommendation review queue with approve / reject / modify.
5. **`ios-cloud-sync`** — an iOS sync layer: the existing chat routes messages
   through the Core API; local Core Data becomes an offline mirror with
   `serverId` + `syncState` tracking. Delivered recommendations render as a
   generic inline action card within the chat conversation — the foundation
   for differentiated prescription, lab, and referral cards in later slices.

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
- The state-licensing invariant — only a physician licensed in the patient's
  state can act on that patient's recommendations — is enforced in code from
  day one, even though the beachhead launches in a single state.
- The PBC charter forbids monetizing PHI; the data model and audit surface are
  shaped so that no marketing-analytics or data-sale extraction path exists
  to be exercised.
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
- **MVP auth**: the Core API issues its own JWT for the MVP, with the
  production identity provider (AWS Cognito under the AWS-direct hosting
  decision; ADR-002's Zitadel reference is now superseded by the AWS-direct
  decision and should be revisited in a follow-up ADR). Confirm the
  HMAC-JWT stopgap is acceptable for local-only development.
- **Local model**: which MedGemma variant (4B vs 27B text) should the dev
  environment standardize on, given local hardware constraints?
- **Physician web app stack**: the proposal recommends server-rendered Go for
  the MVP — confirm, or pull the production web-stack decision forward.
- **Beachhead state**: which single state does the production practice launch
  in? Affects physician licensing operations, not the MVP code.

## Stakeholder Sign-off
- [ ] Engineering
- [ ] Clinical / physician-in-loop owner
- [ ] Compliance / HIPAA

---

**Change ID**: `add-cloud-platform-mvp`
**Status**: Proposed
**Created**: 2026-05-15
**Author**: HouseCall Team
