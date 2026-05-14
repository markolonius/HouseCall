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
          │  - LLM provider(s)       │
          │  - LabCorp / Quest       │
          │  - CommonWell/Carequality│
          │  - Surescripts (Phase 2) │
          └──────────────────────────┘
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
- LLM provider calls: only the minimum necessary context, over a BAA-covered
  endpoint. No PHI to any provider without a signed BAA.
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
- **Patients**: existing iOS auth (password / passcode / biometric) becomes the
  *local unlock*. A separate cloud identity (token-based) authenticates API
  calls. Candidate: AWS Cognito, with the local biometric gating access to the
  stored refresh token.
- **Physicians**: web app auth. MFA mandatory. Likely Cognito or an OIDC
  provider with a healthcare tier.

### Authorization model
- Role-based: `patient`, `physician`, `practice_admin`, `system_admin`.
- Tenant-scoped: a token carries `tenant_id`; the API rejects any cross-tenant
  access.
- Resource-scoped: a physician can only touch patients they have an active
  `CareRelationship` with (or, for `practice_admin`, within their tenant).
- Every authorization decision that touches PHI emits an audit event.

### Open decisions
- Cognito vs. self-managed OIDC — leaning Cognito for the managed-services
  principle, pending a check that it covers physician MFA + license metadata
  cleanly.
- How biometric local unlock binds to the cloud refresh token without weakening
  either.

---

## 6. AI Agent Runtime

This is the highest-risk component and the least specified in PROJECT.md. Phase 1
deliberately ships a **reduced** version.

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
- Model selection (multimodal: vision/audio/text) — Phase 1 is text-only, so
  this can be a text-capable model under a BAA. Multimodal choice deferred to
  Phase 2 with the multimodal exam feature.
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
| Compute | ECS Fargate or Lambda | Core API + agent runtime; Fargate likely for long-lived WebSocket |
| System of record | RDS PostgreSQL | Encrypted, Multi-AZ; row-level security for tenancy |
| Media | S3 | SSE-KMS, presigned URLs, lifecycle policies |
| Identity | Cognito | Patient + physician pools (pending §5 decision) |
| Async jobs | SQS + worker tasks | Integration workers (HealthKit, labs) |
| Secrets | Secrets Manager | LLM keys, integration credentials |
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
| LLM provider BAA | Any PHI to an LLM | [ ] not started |
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
2. This architecture reviewed and the §5 (identity) and §6 (model selection)
   open decisions closed.
3. State launch list decided (drives the physician licensing review and the
   `Physician.statesLicensed` model).
4. LLM provider chosen with a BAA in place.
5. A Phase 1 exit-criteria definition agreed (see PROJECT.md Phase 1).

Until 1, 2, and 4 are done, the iOS app cannot talk to a real backend and Phase 1
is blocked. Extending the iOS app in isolation (e.g., HealthKit capture into
local Core Data) is possible in parallel but is throwaway-risk work until the
sync layer exists.
