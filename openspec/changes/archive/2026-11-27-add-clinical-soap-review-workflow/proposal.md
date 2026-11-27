# Proposal: Clinical SOAP Review Workflow (Server-Side Interview → Physician-Approved Note)

## Why

The just-merged `add-clinical-interview-mode` change made the patient chat behave
like a clinician taking a history, but it runs entirely **client-side** on the
iOS direct-LLM path with a manual "Summarize" button. Two problems:

1. The interview and any clinical summary run on the patient's device with no
   physician in the loop — unacceptable for the production architecture, where
   `ai-agent-runtime`, `physician-in-loop`, and `physician-web-app` already
   require that no clinical content reach a patient without a state-licensed
   physician's review.
2. The interview quality needs work: it repeats itself and re-asks questions the
   patient already answered, and the summary trigger is a manual button rather
   than a clinical judgement that "enough history has been gathered."

This change relocates the interview into the **server-side agent runtime**, makes
the agent **decide for itself** when it has enough information, and routes a
structured **SOAP note** through the existing physician review lifecycle so a
physician approves the Assessment & Plan before anything is delivered to the
patient.

## What Changes

- **Server-side clinical interview.** The agent runtime conducts the multi-turn
  history interview (clinician persona, one question per turn, OPQRST, red-flag
  override) — moved off the iOS device. The interview prompt is hardened so the
  agent does **not repeat itself** and does **not re-ask questions the patient
  already answered** unless clarification is genuinely needed.
- **Agent-decided completion.** The agent emits a completion marker
  (`<READY_FOR_NOTE>`) when it judges the history sufficient; the runtime detects
  it and drafts the note instead of asking another question.
- **SOAP note payload.** A new `soap_note` recommendation payload type with
  structured Subjective / Objective / Assessment / Plan sections, drafted into
  `PENDING_REVIEW` through the existing lifecycle state machine.
- **Direct-to-patient interview questions.** The agent may deliver
  history-gathering **questions** to the patient directly (non-clinical data
  collection), but the **Assessment & Plan** are clinical content and remain
  gated behind physician review — a deliberate, audited carve-out of the existing
  "Agent Cannot Deliver" rule.
- **Physician SOAP review.** The physician web app renders the SOAP note's four
  sections and lets the physician approve, modify (edit the Assessment/Plan), or
  reject — reusing the existing review actions and state-licensing checks.
- **iOS thin client.** Remove the "Summarize" toolbar button; the patient chat
  for this flow runs through cloud sync (core-api + WebSocket) rather than the
  direct-LLM path. The patient receives interview questions live and, after
  approval, the physician-approved note/plan as a delivered recommendation.

## Impact

- **Affected specs**: `ai-agent-runtime` (MODIFIED: interview behaviour, SOAP
  payload, completion marker, narrowed delivery carve-out), `core-api`
  (ADDED: agent→patient interview-message channel + `soap_note` payload),
  `physician-web-app` (ADDED: SOAP review rendering + Assessment/Plan edit),
  `ai-chat-interface` (MODIFIED: remove Summarize control, render server-driven
  interview + delivered note), `ios-cloud-sync` (ADDED: interview-question
  receipt over WebSocket).
- **Affected code**:
  - Backend (Go): `internal/agent/drafter.go` + new interview strategy,
    `internal/agent/client.go` (unchanged endpoint, new prompts), `internal/domain`
    (soap_note payload type/validation), `internal/api` (agent→patient message
    emit), `internal/web` (SOAP review template + handlers).
  - iOS: `AIConversationService` / `ConversationViewModel` / `ChatView`
    (thin-client path, remove Summarize button), recommendation card rendering for
    the delivered SOAP plan.
  - Migrations: extend the recommendations payload-type check if constrained.
- **Supersedes / relocates**: the client-side interview prompt + budgets from
  `add-clinical-interview-mode` (phases 1–3) move server-side; the client
  "Summarize" button (phase 4) is removed. The direct-LLM path may remain only as
  an offline/dev fallback.
- **Operational prerequisite**: this flow requires the backend (Postgres +
  core-api + agent runtime pointed at Ollama `medgemma:4b`) and the physician web
  app to be running — it is no longer a pure on-device demo.
- **Out of scope**: prescription / lab-order / referral payloads; multi-encounter
  history; real e-sign; multi-physician routing; insurance/billing.
