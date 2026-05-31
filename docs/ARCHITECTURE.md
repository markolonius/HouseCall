# ARCHITECTURE.md — Housecall

> System architecture for the Housecall platform. This document is the missing
> foundation referenced in PROJECT.md: it defines how the patient app, physician
> web app, cloud backend, and AI agent fit together, how PHI flows between them,
> and what has to be true before Phase 1 code can start.

**Status:** Draft for review. Nothing here is built yet — the current codebase is
a single-device iOS app (encrypted Core Data, on-device only). This document
describes the target state and the migration path to it.

*Last updated: 2026-05-14*

---

## 1. Guiding Constraints

These shape every decision below:

- **PHI never lives only on one device.** Today's app is single-device Core Data.
  The platform needs a server of record so a physician can see patient data the
  patient entered on their phone.
- **Physician always in the loop.** No AI output reaches a patient without passing
  through a physician-approval state transition. This is an architectural
  invariant, not a UI nicety — it lives in the data model and the API layer.
- **Multi-tenant from day one.** DTC, solo practice, and health-system licensing
  all share one backend. Tenant isolation is a schema-level concern, not a
  later refactor.
- **HIPAA before any cloud PHI.** AWS BAA executed, encryption at rest + in
  transit, audit logging, access controls — all in place before the first real
  patient record is stored server-side.
- **Ship first, optimize later.** Managed AWS services over self-hosted. Boring,
  proven components. No premature scaling work.

---

## 2. System Topology

```
┌─────────────────┐         ┌─────────────────┐
│  Patient iOS    │         │ Physician Web   │
│  App (SwiftUI)  │         │ App (TBD stack) │
└────────┬────────┘         └────────┬────────┘
         │ HTTPS/TLS 1.2+            │ HTTPS/TLS 1.2+
         │ (REST + WebSocket)        │ (REST + WebSocket)
         └─────────────┬─────────────┘
                       │
              ┌────────▼─────────┐
              │   API Gateway    │  AuthN/Z, rate limiting, routing
              └────────┬─────────┘
                       │
        ┌──────────────┼───────────────────────┐
        │              │                       │
┌───────▼──────┐ ┌─────▼────────┐      ┌────────▼─────────┐
│ Core API     │ │ AI Agent     │      │ Integration      │
│ Service      │ │ Runtime      │      │ Workers          │
│ (patients,   │ │ (monitoring  │      │ (HealthKit sync, │
│  conversa-   │ │  loop, recs, │      │  lab results,    │
│  tions,      │ │  escalation) │      │  portal pulls)   │
│  recs,       │ └─────┬────────┘      └────────┬─────────┘
│  protocols)  │       │                       │
└───────┬──────┘       │                       │
        └──────────────┼───────────────────────┘
                       │
          ┌────────────▼─────────────┐
          │  Data Layer              │
          │  - PostgreSQL (RDS)      │  system of record, PHI
          │  - S3                    │  media (audio/video/images)
          │  - Audit log store       │  append-only
          └──────────────────────────┘
                       │
          ┌────────────▼─────────────┐
          │  External (BAA required) │
          │  - LabCorp / Quest       │
          │  - CommonWell/Carequality│
          │  - Surescripts (Phase 2) │
          └──────────────────────────┘

   Note: LLM inference (MedGemma) is self-hosted inside the AWS
   boundary, not an external dependency — see §6 and §8.
```

### Components

| Component | Responsibility | Phase 1 scope |
|---|---|---|
| **Patient iOS app** | Patient-facing surface: chat, dashboard, HealthKit capture, notifications | Reuse existing auth + chat UI; add cloud sync |
| **Physician web app** | Clinical oversight: patient panel, recommendation review queue, protocol view | New build — minimal queue + approve/reject/modify |
| **API Gateway** | TLS termination, authN/Z, rate limiting, request routing | Managed (AWS API Gateway) |
| **Core API Service** | CRUD for patients, conversations, messages, recommendations, protocols; enforces physician-in-loop state machine | New build |
| **AI Agent Runtime** | Per-patient agent: reactive chat responses, recommendation generation, escalation triage | New build — reactive only in Phase 1 |
| **Integration Workers** | Async jobs pulling/pushing external data (HealthKit deltas, lab results) | New build — HealthKit only in Phase 1 |
| **Data Layer** | PostgreSQL system of record, S3 for media, append-only audit store | New build |

### Backend stack

All three backend components — Core API Service, AI Agent Runtime, and
Integration Workers — are built in **Go**, using a minimal / assemble-libraries
approach rather than a batteries-included framework: a lightweight router
(stdlib `net/http` or `chi`), a maintained WebSocket library, and `pgx` for
PostgreSQL are representative choices. Go fits the long-lived WebSocket workload
and deploys as a single static binary to Fargate (see §11 Decision Log for the
Go-vs-Rust evaluation). The specific library set is finalized at backend
kickoff.

---

## 3. PHI Data Flow

Every PHI path must be encrypted in transit (TLS 1.2+) and at rest (AES-256).
The four canonical flows:

### 3.1 Patient submits data (chat message, symptom, vital)
```
iOS app → API Gateway → Core API → PostgreSQL (encrypted at rest)
                                 → Audit log (write event)
                                 → AI Agent Runtime (notified)
```

### 3.2 AI generates a recommendation
```
AI Agent Runtime → Core API → recommendation row created in state PENDING_REVIEW
                            → Audit log (ai_recommendation_generated)
                            → Physician web app notified (WebSocket push)
```
The recommendation is **not** visible to the patient at this point.

### 3.3 Physician reviews
```
Physician web app → API Gateway → Core API
  → recommendation state: PENDING_REVIEW → APPROVED | REJECTED | MODIFIED
  → Audit log (physician_review, with physician ID + decision)
  → if APPROVED/MODIFIED: patient iOS app notified (push), content delivered
```

### 3.4 Escalation (urgent signal)
```
AI Agent Runtime detects urgent signal
  → Core API → escalation row, bypasses normal queue
  → Physician web app: urgent alert (WebSocket + push)
  → if physician unreachable within threshold OR life-threatening:
       patient iOS app prompts call 911
  → Audit log (escalation_raised, escalation_resolved)
```

### PHI handling rules
- LLM inference: MedGemma is self-hosted inside the AWS BAA boundary, so PHI
  never leaves it for a third party. Calls still send only the minimum necessary
  context, over TLS, with no PHI in plaintext logs.
- S3 media (heart/lung audio, skin images): server-side encryption, presigned
  URLs with short TTL, never public.
- Audit store: append-only, no deletes, no PHI content (metadata + IDs only —
  same rule the iOS `AuditLogger` already follows).
- Right-to-be-forgotten: deletion tombstones cascade across PostgreSQL + S3;
  audit log retains the deletion event but not the deleted content.

---

## 4. Data Model Evolution

The current iOS Core Data model is **per-device, per-user**: `User`,
`Conversation`, `Message`, `AuditLogEntry`. The server model is the system of
record and is substantially larger. Core Data becomes a **local cache /
offline mirror**, not the source of truth.

### Server-side core entities (Phase 1)
| Entity | Notes |
|---|---|
| `Tenant` | DTC pool, practice, or health system. Root of isolation. |
| `Patient` | Demographics, assigned physician, tenant FK. |
| `Physician` | License info, states licensed, tenant FK. |
| `CareRelationship` | Patient ↔ Physician link with active/inactive state. |
| `Conversation` | Belongs to a patient; provider metadata. |
| `Message` | Role, content, timestamp; streaming state. |
| `Recommendation` | The physician-in-loop state machine lives here. |
| `Protocol` | Patient-specific or condition-class; AI-drafted, physician-approved. |
| `Escalation` | Urgent-signal bypass record. |
| `HealthObservation` | Vitals / HealthKit data points (FHIR Observation-shaped). |
| `AuditEvent` | Append-only, tenant-scoped. |

### Tenant isolation
Every PHI-bearing row carries a `tenant_id`. Enforced at the query layer
(row-level security in PostgreSQL is the candidate mechanism). No cross-tenant
read path exists in the API.

### Recommendation state machine
```
DRAFT ─► PENDING_REVIEW ─► APPROVED  ─► DELIVERED
                        ├► MODIFIED  ─► DELIVERED
                        └► REJECTED  (terminal)
```
Only `APPROVED` and `MODIFIED` can transition to `DELIVERED`. The transition to
`DELIVERED` is the only path that exposes content to the patient. This invariant
is enforced in the Core API, covered by tests, and audited on every transition.

### iOS migration path
1. Keep the existing local Core Data model.
2. Add a sync layer: local rows get a `serverId` + `syncState`
   (`pending` / `synced` / `conflict`).
3. New data flows to the server first; the local store mirrors it.
4. Offline: writes queue locally, replay on reconnect. Reads serve from cache.
5. The existing encryption stays for local-at-rest; transport encryption is
   additional, not a replacement.

---

## 5. Authentication & Authorization

### Identity
Identity is **AWS Cognito** (per ADR-004, which supersedes ADR-002's
self-hosted-Zitadel decision for the AWS-direct path). Cognito is a
HIPAA-eligible AWS service, so it sits inside the AWS BAA boundary with no
separate identity-vendor BAA. Tenancy is **not** modelled in the IdP — the
`Instance > Organization > Project` hierarchy lives in the Core API data
layer (the `tenants` table, scoped on every PHI row), and Cognito carries a
`custom:tenant_id` claim. See §11 Decision Log (ADR-004) for the full
rationale and the Zitadel / Authentik alternatives considered, and the
re-evaluation trigger (practice/health-system customers needing IdP-managed
per-org admin scoping).

- **Patients**: existing iOS auth (password / passcode / biometric) becomes the
  *local unlock*. A separate cloud identity (Cognito-issued OIDC tokens)
  authenticates API calls, with the local biometric gating access to the stored
  refresh token.
- **Physicians**: web app auth via Cognito. MFA mandatory.

### Authorization model
- Role-based: `patient`, `physician`, `practice_admin`, `system_admin`.
- Tenant-scoped: a token carries `tenant_id` (the Cognito `custom:tenant_id`
  claim); the API rejects any cross-tenant access.
- Resource-scoped: a physician can only touch patients they have an active
  `CareRelationship` with (or, for `practice_admin`, within their tenant).
- Every authorization decision that touches PHI emits an audit event.

### Open decisions
- Physician license metadata (states licensed, NPI, DEA) — stored as Cognito
  custom attributes vs. in the Core API `Physician` row. Leaning Core API
  row as the source of truth, with Cognito holding only auth identity.
  (`add-pa-chronic-disease-launch` already treats the Core API row as the
  source of truth for PA license status.)
- How biometric local unlock binds to the cloud refresh token without weakening
  either.

---

## 6. AI Agent Runtime

This is the highest-risk component and the least specified in PROJECT.md. Phase 1
deliberately ships a **reduced** version.

### Model
The agent runs on **MedGemma** (Google's open-weights medical model), **self-
hosted** — production on AWS GPU inference (SageMaker endpoint or EC2/EKS + vLLM)
inside the AWS BAA boundary, development on a locally hosted model. Both are
served behind an OpenAI-compatible interface, so the same client code runs in
both environments (and aligns with the existing iOS `CustomProvider`). PHI never
leaves the AWS BAA boundary, so there is no model-vendor BAA. Phase 1 is
text-only, which MedGemma's text variant covers; the multimodal choice is
deferred to Phase 2 with the multimodal exam feature.

MedGemma is shipped by Google as a developer model that *requires validation* —
it is not a cleared clinical product. This is exactly why the physician-in-loop
invariant and the eval harness below are non-negotiable.

See §11 Decision Log for the hosting alternatives considered.

### Phase 1: reactive agent
- Stateless request/response: patient sends a message → agent responds, using
  conversation history + the patient's approved protocol as context.
- Can generate a `Recommendation` in `PENDING_REVIEW` state. Cannot deliver
  anything to the patient directly.
- Runs as a service behind the API, one logical agent context per patient
  (context = conversation history + protocol + recent observations).

### Phase 2+: proactive agent
- Scheduled monitoring loop (per-patient cadence driven by active conditions).
- Background evaluation of incoming HealthObservations against protocol
  thresholds → recommendation or escalation.
- This needs a scheduler, a durable per-patient agent state store, and an eval
  harness — explicitly **deferred**.

### Guardrails (Phase 1, non-negotiable)
- Hard architectural block on patient-facing delivery without physician approval.
- Escalation detection runs on every patient interaction even in the reactive
  model.
- Prompt/response logging (metadata + audit, no PHI in plaintext logs).
- An eval set for recommendation quality before any real patient use — small,
  but it must exist.

### Open decisions
- GPU inference platform — SageMaker endpoint vs. EC2/EKS + vLLM. Pick on cost
  and ops overhead.
- MedGemma variant/size for Phase 1 (4B vs 27B text) — pick against the eval set
  and latency budget.
- Agent framework vs. hand-rolled orchestration — recommend hand-rolled and
  minimal for Phase 1; revisit if the proactive loop justifies a framework.

---

## 7. Sync Protocol (iOS ↔ Cloud)

- **Transport**: REST for CRUD, WebSocket for live updates (streaming AI
  responses, recommendation-delivered push, escalation alerts).
- **Write path**: client writes locally (queued) → POSTs to server → server
  assigns `serverId` → client reconciles.
- **Read path**: client pulls deltas since last sync cursor; server is
  authoritative on conflict.
- **Conflict policy (Phase 1)**: server wins; conflicting local edits are
  preserved in a `conflict` state and surfaced rather than silently dropped.
  Patient-authored content rarely conflicts in practice (single patient, single
  device assumption holds for Phase 1).
- **Offline**: full read of cached data; writes queue and replay. The existing
  "offline conversation viewing" behavior is preserved.

---

## 8. AWS Service Mapping

All under an executed BAA. Managed services preferred.

| Concern | Service | Notes |
|---|---|---|
| API edge | API Gateway | TLS, throttling, routing |
| Compute | ECS Fargate or Lambda | Core API + agent runtime as Go static binaries; Fargate likely for long-lived WebSocket |
| System of record | RDS PostgreSQL | Encrypted, Multi-AZ; row-level security for tenancy |
| Media | S3 | SSE-KMS, presigned URLs, lifecycle policies |
| Identity | AWS Cognito (per ADR-004) | OIDC; HIPAA-eligible AWS service; tenancy modelled in the Core API `tenants` table, carried as a `custom:tenant_id` claim |
| LLM inference | Self-hosted MedGemma — SageMaker endpoint or EC2/EKS + vLLM (GPU) | OpenAI-compatible interface; inside the BAA boundary |
| Async jobs | SQS + worker tasks | Integration workers (HealthKit, labs) |
| Secrets | Secrets Manager | Integration credentials, DB creds, signing keys |
| Audit store | RDS (append-only table) or dedicated store | No deletes; consider separate DB |
| Observability | CloudWatch | No PHI in logs — enforced |
| Push | APNs (via SNS) | Recommendation-delivered, escalation alerts |

### Explicitly deferred
- HealthLake / FHIR-native storage — Phase 2+, when EHR interop justifies it.
  Phase 1 stores FHIR-*shaped* data in PostgreSQL without a FHIR server.
- Multi-region — single region for Phase 1.

---

## 9. Compliance Gates

Each is a hard gate with an owner and a target date — none are "do later."

| Gate | Blocks | Status |
|---|---|---|
| AWS BAA executed | Any cloud PHI storage | [ ] not started |
| HIPAA security risk assessment | Production launch | [ ] not started |
| LLM inference in the BAA boundary | Any PHI to the model | [x] resolved — MedGemma self-hosted on AWS; covered by the AWS BAA, no separate model-vendor BAA |
| Lab integration BAAs (LabCorp, Quest) | Lab result ingestion | [ ] Phase 1 deferred candidate |
| FDA SaMD analysis | Clinical claims in marketing | [ ] not started — assumption, not analysis |
| State telehealth / physician licensing review | First patient in any state | [ ] not started |
| EPCS / DEA (e-prescribing) | E-prescribing feature | [ ] Phase 2 |
| SOC 2 / HITRUST | Health-system licensing | [ ] Phase 3 |
| Penetration test | Production launch | [ ] not started |
| Accessibility audit (WCAG 2.1 AA) | Production launch | [ ] not started |

**The FDA gate matters most early:** PROJECT.md asserts the platform "stays below
the FDA SaMD threshold." That needs to be a real regulatory analysis with a
documented conclusion, not an assumption — it shapes what the AI is allowed to
say and do.

---

## 10. What Has to Be True Before Phase 1 Code Starts

1. AWS account with BAA executed.
2. Launch state confirmed — set by the supervising physician's licensure once
   that physician is confirmed; drives the telehealth licensing review and the
   `Physician.statesLicensed` model.
3. A Phase 1 exit-criteria definition agreed (see PROJECT.md Phase 1).

The backend stack (§2 — Go), §5 (identity — AWS Cognito per ADR-004), and §6
(model selection — MedGemma) decisions are now closed; Cognito is a
HIPAA-eligible AWS service and MedGemma runs inside the AWS BAA boundary. Until
item 1 is done, the iOS app cannot talk to a real backend
and Phase 1 is blocked. Extending the iOS app in isolation (e.g., HealthKit
capture into local Core Data) is possible in parallel but is throwaway-risk work
until the sync layer exists.

---

## 11. Decision Log

Architecturally significant decisions, with the alternatives considered and why
they were ruled out. New decisions are appended here.

### ADR-001: Backend stack — Go
**Date:** 2026-05-14 · **Status:** Accepted

**Context:** The backend (Core API, AI Agent Runtime, Integration Workers) is
greenfield; `openspec/project.md` marked the technology "TBD".
**Decision:** Build all three backend components in Go, using a minimal /
assemble-libraries approach rather than a batteries-included framework.
**Alternatives considered:**
- *Rust* — by 2026 industry consensus ("Go for the network layer, Rust for the
  compute-intensive core") this is not a Rust project: the Phase 1 Core API is
  I/O-bound and model inference is offloaded to a separate vLLM process, so
  there is no compute-intensive core. Slower iteration and scarcer hiring also
  cut against PROJECT.md's "ship first" principle.
- *Zig* — pre-1.0, with an immature web / Postgres / async ecosystem; a
  liability for a HIPAA backend that must ship and be maintained.
- *TypeScript* — weaker at long-lived connections; "one language across web app
  + backend" was not decisive.
- *Python* — its main draw (ML ecosystem) disappears because the AI Agent
  Runtime is HTTP orchestration against an OpenAI-compatible endpoint, not ML
  code.
**Rationale:** The workload is I/O-bound with heavy WebSocket concurrency, which
Go fits best; fast compiles and onboarding; single static-binary deploys to
Fargate; shared language with Zitadel. The one real Rust draw — compile-time
type-state for the recommendation state machine — is covered in Go by the
tests + audit approach §4 already commits to.

> **Note (2026-05-29, ADR-004):** the "shared language with Zitadel"
> sub-point is now moot — identity moved to AWS Cognito, which is not a
> self-hosted Go service. The Go decision stands on its other merits
> (WebSocket concurrency, single-binary deploys, fast onboarding); this
> sub-point is left in place as part of the historical record.

### ADR-002: Identity provider — self-hosted Zitadel
**Date:** 2026-05-14 · **Status:** **Superseded by ADR-004 (2026-05-29)** for
the AWS-direct production path. The original decision is preserved below for
historical reasoning; the live decision is in ADR-004.

**Context:** The platform needs a HIPAA-suitable identity provider that supports
the multi-tenant invariant (§1) and runs inside the AWS BAA boundary.
**Decision:** Self-host Zitadel (Apache 2.0), inside the AWS BAA boundary.
**Alternatives considered:**
- *Hanko* — strong project (Go, stable, passkey-first, OIDC/SAML/MFA), but its
  multi-tenancy / organizations / roles are still "in development" on its own
  roadmap, conflicting with the "multi-tenant from day one" invariant; its
  backend is also AGPL-3.0.
- *Keycloak* — mature but Java (off-stack) and heavy to operate.
- *Authentik* — Python; multi-tenancy is explicitly not a core feature, weak for
  strict tenant isolation.
- *Ory* — Hydra is only an OAuth2 token server, not a full identity provider.
- *AWS Cognito / better-auth* — third-party or stack-coupled; superseded once
  the Go backend stack was chosen.
**Rationale:** Zitadel is the only Go-native option built ground-up for the
`Instance > Organization > Project` hierarchy HouseCall's tenancy model needs,
with event-sourced audit logs that fit HIPAA, under a permissive license.

### ADR-003: LLM inference hosting — self-hosted MedGemma on AWS
**Date:** 2026-05-14 · **Status:** Accepted

**Context:** Phase 1 needs a text-capable medical model with no PHI leaving a
BAA-covered boundary.
**Decision:** Self-host MedGemma — production on AWS GPU inference (SageMaker
endpoint or EC2/EKS + vLLM), development on a locally hosted model, both behind
an OpenAI-compatible interface.
**Alternatives considered:**
- *Google Vertex AI Model Garden* — splits infrastructure onto GCP and requires
  a separate Google BAA.
- *Third-party inference host* — variable BAA availability and terms.
**Rationale:** PHI never leaves the AWS BAA boundary, so no model-vendor BAA is
needed; the OpenAI-compatible vLLM endpoint means the same client code runs in
development (local model) and production.

### ADR-004: Identity provider — AWS Cognito (supersedes ADR-002 for the AWS-direct path)
**Date:** 2026-05-29 · **Status:** Accepted

**Context:** Two prior decisions were in conflict and the cloud-MVP
`design.md` §8 flagged the gap explicitly. ADR-002 (2026-05-14) chose
self-hosted Zitadel because identity needed to run inside the AWS BAA
boundary and Zitadel's `Instance > Organization > Project` model is the
cleanest native fit for HouseCall's multi-tenancy invariant (§1). The
cloud-MVP design landed on **AWS Cognito** for the AWS-direct production
path and noted that ADR-002 "should be revisited in a follow-on ADR." The
solo-founder launch decisions (`docs/LAUNCH_STRATEGY.md`) and the
DTC-only Phase 1 GTM make the trade-off concrete enough to close.

**Decision:** Use **AWS Cognito User Pools** for production identity on
the AWS-direct path. Tenancy is modelled in the application data layer
(the `tenants` table, owned by Core API in `add-cloud-platform-mvp`),
not by the IdP. Cognito issues JWTs with a `custom:tenant_id` claim;
the same JWT middleware in `internal/api` validates both MVP-local HMAC
tokens (today) and Cognito-issued tokens (production).

**Alternatives considered:**
- *Self-hosted Zitadel (ADR-002)* — strongest native multi-tenancy
  hierarchy and event-sourced audit, but its primary advantage
  (IdP-managed `Instance > Org > Project` hierarchy with per-org admins)
  doesn't pay off until practice-license and health-system-license
  customers arrive and need to manage their own clinician pools. For
  Phase 1's DTC-only launch with a solo founder, the operational tax of
  running an IdP (patching, RDS replicas for the eventstore, blue/green
  deploys, owning the security incident response surface for a critical
  authn dependency) outweighs the architectural cleanness.
- *Authentik* — re-examined 2026-05-29 against its current state.
  Multi-tenancy via `django-tenants` is real but **Enterprise-gated**;
  the architecture is one Django app over per-tenant Postgres schemas
  rather than a model-level hierarchy. Runtime is heavier (server +
  Celery worker + Redis + Postgres in Python/Django vs. Cognito's zero
  ops or Zitadel's single Go binary + Postgres). Same fundamental fit
  problem as Zitadel — its native multi-tenancy mainly matters when the
  IdP itself enforces per-org admin scoping, which Phase 1 doesn't need
  — without the AWS-managed operational savings Cognito offers.
- *Hanko, Keycloak, Ory* — unchanged from ADR-002 alternatives.

**Rationale:**
- **Tenancy lives in the data model, not the IdP.** The `tenants` table
  already exists in `backend/migrations/0001_init.sql` and every PHI row
  is scoped to it at the schema layer (composite `(tenant_id, parent_id)`
  FKs) and the application layer (every store function takes a
  `TenantID`). The IdP's job is authenticating *people*; the
  organization hierarchy is enforced by HouseCall code. A `custom:tenant_id`
  claim on a Cognito JWT is sufficient — Stripe, Linear, Notion, and most
  vertical-SaaS products use this pattern. Zitadel's IdP-managed
  hierarchy is leverage we don't cash in until practice/health-system
  customers manage their own user pools, which is GTM Phase 2/3.
- **HIPAA boundary.** Cognito is HIPAA-eligible under the AWS BAA. It is
  already inside the boundary because it *is* an AWS service. No
  separate IdP-vendor BAA is needed.
- **Operational savings for a solo founder.** Cognito eliminates an
  entire operational surface: no IdP patching, no Postgres replica to
  manage for the eventstore, no upgrade path, no blue/green for the
  authn-critical dependency. The cognitive budget that ADR-002 would
  have spent on running Zitadel is redirected to clinical protocols and
  the physician-in-loop loop, which are differentiating.
- **Audit trail.** Cognito events flow to CloudWatch and CloudTrail
  (admin actions). For HIPAA §164.312(b), the application's own
  `audit_events` table records every PHI-touching action with a
  Cognito-derived `actor_id` — that's the source of truth. The IdP's
  event log is a secondary signal, which Cognito provides.
- **Reversibility.** Cognito's User Migration Lambda trigger lets a
  migration to Zitadel or another OIDC provider re-hash passwords on
  first login. Migration is not painless but it is not a one-way door —
  this matters because the AWS-managed simplification is worth taking
  even with non-zero exit cost.
- **MVP code stays the same.** The Core API JWT middleware in Phase 2
  validates HMAC-signed tokens today. Cognito-issued tokens are
  validated through the same middleware with a JWKS verifier swap; the
  domain and store layers do not change.

**Re-evaluation trigger:** Re-open this ADR when the first practice-
license or health-system-license customer is signed and requires
per-org admin scoping that Cognito Groups + custom claims cannot model
cleanly. At that point Zitadel or Authentik should be re-evaluated
against the then-current state.

**Follow-up work (completed 2026-05-29):**
- The body of this document (§2, §5 Authentication & Authorization, §8
  AWS Service Mapping, §10, §12) has been swept to replace Zitadel
  references with Cognito. Remaining "Zitadel" mentions are confined to
  the historical ADR-001 / ADR-002 text and to this ADR's
  alternatives-considered discussion.
- `add-cloud-platform-mvp` `design.md` §8 now points to this ADR.

---

## 12. Production Security Prerequisites (Out of MVP Scope)

The local-development MVP (`add-cloud-platform-mvp`) does not implement the
controls below — it runs on a developer machine with no real PHI. The controls
in this section **must be in place before the first real patient connects** to
any production environment. Healthcare is now the most-attacked sector
(Change Healthcare 2024, ~$2.87B impact; CommonSpirit; Ascension; AHA reports
ransomware as the #1 hospital cyber threat), and the difference between orgs
that survive and orgs that pay is the discipline of doing all of the following,
not any single one.

- **Backups** — 3-2-1-1 with one immutable/offline copy. S3 Object Lock in
  compliance mode in a separate AWS account whose root is break-glass. Backup
  credentials unreachable from the production plane. Restore drills on a
  defined cadence (not just backup-success metrics).
- **Identity & access** — phishing-resistant MFA (WebAuthn/FIDO2) for all
  staff, admins, and remote access; SSO with conditional access; just-in-time
  admin elevation; no shared accounts. Builds on ADR-004 (AWS Cognito).
- **Endpoints & email** — EDR on every endpoint (CrowdStrike / SentinelOne /
  Defender for Endpoint); modern email security with attachment sandboxing and
  URL rewriting; DMARC/SPF/DKIM enforced; Office macros disabled by policy.
- **Network** — clinical, corporate, and development planes segmented;
  production data tier unreachable from user-laptop subnets; egress
  restrictions; no internet-exposed RDP or legacy remote-access gateways.
- **Patching** — CISA KEV-driven SLA; minimized internet exposure of services.
- **Supply chain** — SBOMs, dependency scanning, signed container images,
  pinned base images. GitHub branch protection, required reviews, signed
  commits, no force-push to main. Secrets in AWS Secrets Manager / KMS,
  rotated. CI runners without standing production credentials.
- **Detection & response** — central audit log → SIEM with 6-year retention;
  behavioural detections (mass file reads/writes, privilege escalation,
  impossible travel); 24/7 monitoring (MDR vendor unless an in-house SOC
  exists); pre-signed DFIR retainer; written and rehearsed IR plan; HHS/OCR
  60-day breach-notification playbook.
- **Third-party / BAA** — every PHI-adjacent vendor under BAA and security
  review (model provider, hosting, identity, email). Vendor-compromise plan
  (Change Healthcare cascade lesson).
- **Framework** — HHS HPH Cybersecurity Performance Goals (CPGs) as the
  explicit compliance target, with NIST CSF 2.0 or HITRUST CSF as the overall
  map and HICP/405(d) as the healthcare-specific playbook (recognized safe
  harbor under HHS enforcement discretion).

Tracked as the OpenSpec change `add-production-security-hardening` (backlog
stub).
