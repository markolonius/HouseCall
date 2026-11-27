# Design: Clinical SOAP Review Workflow

## Architecture recap (existing, reused)

```
patient (iOS) --message--> core-api ingest --> agent runtime (Ollama)
                                                   |
   (NEW) interview question <--WebSocket-- agent --+  (continue interview)
                                                   |
                              <READY_FOR_NOTE> --> draft soap_note recommendation
                                                   DRAFT -> PENDING_REVIEW
                                                   |
                              queue.updated --> physician web app review queue
                                                   |
   physician approve / modify(A&P) / reject  --> APPROVED|MODIFIED|REJECTED
                                                   |
                              deliver --> DELIVERED --recommendation card--> patient (iOS)
```

The lifecycle state machine (`internal/domain/recommendation.go`), the review
actions + state-licensing (`internal/review`), the physician web app
(`internal/web`), the Ollama client (`internal/agent/client.go`), and the iOS
`CloudSyncCoordinator` + recommendation-card rendering all already exist. This
change adds an **interview strategy** in front of the drafter, a **SOAP payload
type**, a **direct agent→patient question channel**, and the **SOAP review UI**.

## Key decision 1: two classes of agent output

The existing rule (`ai-agent-runtime`: "The Agent Cannot Deliver") forbids the
agent from sending clinical content to a patient without physician review. We
split agent output into two clearly-typed classes:

- **Interview question (non-clinical, direct).** History-gathering questions
  ("When did the headache start?"). These are data collection, contain no
  assessment or plan, and are delivered straight to the patient as assistant
  messages. They never enter the recommendation lifecycle.
- **SOAP note (clinical, review-gated).** The Subjective/Objective/Assessment/
  Plan note. This is a `soap_note` recommendation that MUST pass through
  `PENDING_REVIEW` → physician → `APPROVED|MODIFIED` → `DELIVERED`. The agent has
  no path to deliver it.

This carve-out is the security-sensitive heart of the change and is spelled out
explicitly in the `ai-agent-runtime` spec delta. The marker that separates the
two classes is model-emitted and server-detected, never patient-visible.

## Key decision 2: completion marker

The interview system prompt instructs the model to emit a single sentinel token
on its own line — `<READY_FOR_NOTE>` — when (and only when) it has enough history
to write the note. The agent runtime:

1. Generates the next turn from the conversation.
2. If the response contains the marker: strip the marker, discard any partial
   question text after it, and switch to **note drafting** (do NOT send the
   marker or trailing text to the patient).
3. Otherwise: deliver the response to the patient as an interview question.

Marker detection is a server-side string check; the marker is defined as a
constant so the prompt and the parser cannot drift. If the model never emits the
marker, a safety cap (configurable max interview turns) forces a draft so an
interview cannot run unbounded.

## Key decision 3: no-repeat / no-re-ask

Handled primarily in the interview prompt: the agent is instructed to read the
full conversation each turn, NOT repeat a question already asked, NOT ask for
information the patient already provided, and to ask only the single most
valuable next question — moving to clarification only when an answer was
ambiguous or incomplete. A short few-shot exemplar demonstrates skipping an
already-answered dimension. (The full conversation is already passed to the model
by `drafter.draft`, so the context needed to avoid repeats is present.)

## SOAP payload shape

`payload_type = "soap_note"`, payload JSON:

```json
{
  "subjective": "...",   // history of present illness in the patient's words
  "objective": "...",    // reported objective findings (no exam fabrication)
  "assessment": "...",   // clinical impression — REVIEW-GATED
  "plan": "..."          // recommended plan — REVIEW-GATED
}
```

`draft_content` continues to hold the full human-readable note for the existing
review surface. The agent is instructed never to fabricate objective exam
findings it could not have obtained in a text interview (objective stays limited
to patient-reported vitals/measurements or "none reported").

## Backend changes

- **Interview strategy** (`internal/agent`): a new path that, per patient
  message, either emits a question (delivered to patient) or, on marker, drafts
  the `soap_note` recommendation via the existing DRAFT→PENDING_REVIEW txn
  pattern in `drafter.go`. Reuses `ModelClient`, `Txn`, audit, and
  `SendToPhysicians`.
- **Patient notifier**: analogue of `PhysicianNotifier` to push an
  agent interview message to the patient's WebSocket and persist it as an
  assistant message (so history is complete for later turns and offline replay).
- **Domain**: register `soap_note` as a valid payload type; validate the four
  sections are present on draft. Lifecycle transitions are unchanged.
- **Audit**: interview questions and note drafting both audited with identifiers
  + coarse event types only — never PHI, never model text (matches existing
  drafter discipline).

## Physician web app

Extend the review template (`internal/web/templates`) so a `soap_note`
recommendation renders the four sections, with the Assessment and Plan editable.
"Approve" = `approve`; editing A/P then saving = `modify`; "Reject" = `reject`.
State-licensing checks are unchanged (physician must be licensed in the patient's
state). Delivery (`deliver`) of an APPROVED/MODIFIED note remains the existing
internal step.

## iOS thin client

- Remove the "Summarize" toolbar button and the client `requestSummary()` path
  for this flow.
- Patient chat for the SOAP flow runs through `CloudSyncCoordinator` (core-api +
  WebSocket), not direct-LLM. Interview questions arrive as assistant messages
  via the existing message-sync + WebSocket path; the delivered approved note
  renders as a recommendation card (existing `RecommendationCard`).
- The client-side interview prompt / phase-state / token-budget code from
  `add-clinical-interview-mode` is retired from the cloud path (kept only if a
  direct-LLM offline mode is still wanted; otherwise removed in a follow-up).

## Safety / HIPAA

- Assessment & Plan never reach the patient without a state-licensed physician
  transition — enforced by the lifecycle machine, not by UI.
- No PHI in logs/audit (identifiers + coarse reasons only), consistent with
  existing drafter and review code.
- Marker and any trailing text are stripped server-side so prompt-control tokens
  are never patient-visible.
- Interview turn cap prevents unbounded model usage / runaway interviews.

## Alternatives considered

- **Client interview, server review** (rejected per user decision): smaller, but
  runs PHI + interview on-device and bypasses the agent runtime.
- **Inline transition / periodic readiness check** (rejected): less controllable
  or doubles model calls vs. a single model-emitted marker.
