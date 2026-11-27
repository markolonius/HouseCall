# Proposal: Agent Care Loop — From Intake Scribe to Midlevel-Style Care Coordinator

## Why

The cloud-MVP agent behaves like an intake scribe: it interviews the patient,
drafts a SOAP note into `PENDING_REVIEW`, and stops. Everything after the
physician's decision is silent or static. Observed consequences in the running
system (2026-07-15):

- A patient message into a conversation whose interview was already complete
  silently produced a *second* SOAP note and no patient-facing output — the
  app appears dead (tracked as bead `HouseCall-lkzs`).
- An approved plan reaches the patient as a static recommendation card; the
  agent will not explain it or answer questions about it.
- A physician rejection (`REJECTED` is terminal) dead-ends: the agent never
  learns why, never gathers the missing information, and never re-presents.
- The interview treats "crushing chest pain" and "mild seasonal congestion"
  with the same polite multi-turn pacing — there is no urgency triage.

A midlevel provider (PA/NP) does four things the agent does not: explains the
physician-approved plan back to the patient, revises and re-presents when the
physician pushes back, knows what phase of care the encounter is in, and
escalates red flags immediately. This change adds those four behaviours while
keeping the physician-in-loop carve-out fully intact: the agent still never
delivers clinical content that a physician has not approved.

## What Changes

- **NEW**: Server-side conversation care-phase state machine
  (`INTAKE` → `AWAITING_REVIEW` → `PLAN_DELIVERED`, with `AWAITING_REVIEW` →
  `INTAKE` on rejection) driving per-phase agent behaviour and system prompts.
- **NEW**: Review-pending acknowledgement — when the agent hands off to the
  physician it tells the patient so, instead of going silent (closes
  `HouseCall-lkzs`).
- **NEW**: Post-approval plan relay — in `PLAN_DELIVERED`, the agent answers
  patient questions grounded strictly in the physician-approved content; it
  may explain, never extend or alter.
- **NEW**: Rejection revision loop — physicians must give a reason when
  rejecting; the agent resumes the interview targeting the gap and drafts a
  fresh recommendation.
- **NEW**: Red-flag triage — every patient message is screened for emergency
  presentations before the normal interview turn; red flags produce an
  immediate emergency-referral message and an urgent physician notification.
- **MODIFIED**: Physician web app reject action now requires a reason.

## Impact

- **Affected specs**:
  - `ai-agent-runtime` — ADDED requirements (care-phase machine,
    acknowledgement, plan relay, revision loop, triage).
  - `physician-in-loop` — ADDED requirement (rejection reason capture). The
    recommendation lifecycle itself is unchanged; `REJECTED` stays terminal
    for the rejected row — revision creates a new recommendation.
  - `core-api` — ADDED requirement (care-phase persistence and exposure).
  - `physician-web-app` — MODIFIED requirement (reject requires reason).
- **Affected code**: `backend/internal/agent` (drafter branching, new
  prompts, triage classifier call), `backend/internal/store` +
  `backend/migrations` (conversation `care_phase` column, recommendation
  `rejection_reason`), `backend/internal/api` (phase in conversation DTO,
  reject reason validation), `backend/internal/web` (reject reason form
  field). iOS renders relay/acknowledgement turns through the existing
  message-sync path — no iOS code change is required in this slice.
- **Dependencies**: `add-cloud-platform-mvp` (implemented). Independent of —
  and sequenced before — `add-pa-chronic-disease-launch`, whose
  strategy-selection layer will plug into the same per-phase dispatch.
- **Out of scope**: proactive/scheduled agent behaviour (vitals check-ins
  belong to `add-pa-chronic-disease-launch`), multi-conversation longitudinal
  memory, model fine-tuning, physician-to-agent free-form chat, any new
  payload types.
