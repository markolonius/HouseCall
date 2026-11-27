# ai-agent-runtime Specification

## Purpose
TBD - created by archiving change add-cloud-platform-mvp. Update Purpose after archive.
## Requirements
### Requirement: Reactive Recommendation Drafting

When a patient message is persisted, the AI Agent Runtime SHALL conduct a
clinical history interview by generating the next interview turn from the
tenant-scoped conversation context, and SHALL produce a `soap_note`
Recommendation in the `PENDING_REVIEW` state ONLY when it determines that
sufficient history has been gathered. The runtime SHALL act only in response to a
patient message in the MVP — no proactive or scheduled behaviour.

#### Scenario: A patient message during the interview produces a question

- **GIVEN** a persisted patient message on a conversation still gathering history
- **WHEN** the AI Agent Runtime processes it
- **THEN** it assembles context from that conversation's messages only
- **AND** it generates a single next interview question
- **AND** it does NOT create a Recommendation for that turn

#### Scenario: Sufficient history produces a pending SOAP recommendation

- **GIVEN** a conversation in which the agent has gathered sufficient history
- **WHEN** the AI Agent Runtime processes the next patient message
- **THEN** it produces a `soap_note` Recommendation in `PENDING_REVIEW`
- **AND** a `queue.updated` event is emitted for the supervising physician

### Requirement: Local Model Endpoint Integration

The AI Agent Runtime SHALL call a configurable OpenAI-compatible model endpoint.
The endpoint URL SHALL be configuration-driven so the same code path serves a
local development model and, later, a production-hosted model.

#### Scenario: The runtime calls the configured endpoint

**Given** a configured OpenAI-compatible model endpoint
**When** the AI Agent Runtime drafts a recommendation
**Then** it sends the assembled context to that endpoint
**And** it uses the model's response as the recommendation's draft content

#### Scenario: The model endpoint is unavailable

**Given** the configured model endpoint is unreachable or returns an error
**When** the AI Agent Runtime attempts to draft a recommendation
**Then** no Recommendation is created
**And** an `ai_interaction_failed` audit event is written
**And** no error content is presented to the patient as a clinical response

---

### Requirement: The Agent Cannot Deliver

The AI Agent Runtime SHALL deliver only non-clinical history-gathering questions
directly to the patient. It SHALL only ever create a clinical Recommendation
(including a `soap_note`) in `DRAFT` and move it to `PENDING_REVIEW`, and SHALL
have no code path that transitions a Recommendation to `APPROVED`, `MODIFIED`, or
`DELIVERED`. The Assessment and Plan SHALL never reach the patient without a
physician transition.

#### Scenario: Interview questions are delivered, clinical content is not

- **GIVEN** the AI Agent Runtime generates an interview question
- **WHEN** the turn is processed
- **THEN** the question is delivered to the patient as an assistant message
- **AND** no Assessment or Plan content is delivered

#### Scenario: SOAP output always lands in PENDING_REVIEW

- **GIVEN** the AI Agent Runtime has drafted a `soap_note`
- **WHEN** the draft is complete
- **THEN** the recommendation is in `PENDING_REVIEW`
- **AND** the runtime has not transitioned it any further

### Requirement: Guidance Payload Only In MVP

The AI Agent Runtime SHALL produce Recommendations with `payload_type` =
`soap_note` for the clinical interview flow and SHALL NOT produce `prescription`,
`lab_order`, or `referral` payloads in this slice. The runtime SHALL remain
structured so that additional payload types can be added as new agent strategies
without changing the review lifecycle.

#### Scenario: A drafted clinical recommendation is a soap_note payload

- **GIVEN** the AI Agent Runtime has drafted a clinical recommendation
- **WHEN** the draft is persisted
- **THEN** the recommendation's `payload_type` is `soap_note`
- **AND** the runtime does not write `prescription`, `lab_order`, or `referral`

### Requirement: Agent-Decided Interview Completion

The AI Agent Runtime SHALL determine when sufficient history has been gathered by
detecting a model-emitted completion marker, and SHALL enforce a configurable
maximum number of interview turns after which it drafts the note regardless.

#### Scenario: Completion marker triggers note drafting

- **GIVEN** the model output for a turn contains the completion marker
- **WHEN** the runtime processes the output
- **THEN** it strips the marker and any trailing text
- **AND** it drafts a `soap_note` recommendation instead of sending a question
- **AND** the marker is never delivered to the patient

#### Scenario: Turn cap forces a draft

- **GIVEN** an interview has reached the configured maximum number of turns
  without a completion marker
- **WHEN** the next patient message is processed
- **THEN** the runtime drafts a `soap_note` recommendation rather than continuing

### Requirement: Non-Repeating History Interview

The AI Agent Runtime SHALL conduct the interview without repeating itself and
without re-asking for information the patient has already provided, asking for
clarification only when a previous answer was ambiguous or incomplete.

#### Scenario: An already-answered dimension is not re-asked

- **GIVEN** the patient has already stated the onset of their symptom
- **WHEN** the agent generates the next interview turn
- **THEN** it does not ask again for the onset
- **AND** it asks for a different, not-yet-gathered history detail

### Requirement: Conversation Care Phase State Machine

Each server conversation SHALL carry a care phase — `INTAKE`,
`AWAITING_REVIEW`, or `PLAN_DELIVERED` — and the AI Agent Runtime SHALL select
its behaviour for a patient message from that phase. Phases SHALL move only
`INTAKE` → `AWAITING_REVIEW` (on SOAP draft), `AWAITING_REVIEW` →
`PLAN_DELIVERED` (on recommendation delivery), `AWAITING_REVIEW` → `INTAKE`
(on rejection), and `PLAN_DELIVERED` → `INTAKE` (on a new complaint). Each
phase transition SHALL be committed in the same database transaction as the
event that causes it.

#### Scenario: Drafting a SOAP note moves the conversation to AWAITING_REVIEW

**Given** a conversation in `INTAKE`
**When** the runtime commits a drafted SOAP recommendation
**Then** the conversation's care phase is `AWAITING_REVIEW` in the same
transaction

#### Scenario: A message during AWAITING_REVIEW does not draft again

**Given** a conversation in `AWAITING_REVIEW` with a pending recommendation
**When** the patient sends another message
**Then** the runtime does not run an interview turn and does not create a
second recommendation
**And** the patient receives an assistant message stating their report is with
the physician

#### Scenario: Delivery moves the conversation to PLAN_DELIVERED

**Given** a conversation in `AWAITING_REVIEW`
**When** its recommendation transitions to `DELIVERED`
**Then** the conversation's care phase is `PLAN_DELIVERED` in the same
transaction

---

### Requirement: Review-Pending Acknowledgement

The AI Agent Runtime SHALL, when it concludes an interview and drafts a
recommendation, persist a patient-facing assistant acknowledgement message stating
that the information has been sent to the physician for review. The
acknowledgement SHALL be non-clinical fixed text and SHALL NOT reveal any of
the drafted Assessment or Plan.

#### Scenario: The patient is told about the physician handoff

**Given** a patient message that causes the runtime to draft a SOAP
recommendation
**When** the draft is committed
**Then** the patient receives an assistant acknowledgement message in the same
conversation
**And** the acknowledgement contains none of the drafted recommendation's
clinical content

---

### Requirement: Post-Approval Plan Relay

In `PLAN_DELIVERED`, the AI Agent Runtime SHALL answer patient questions using
context assembled only from the delivered recommendation's final content and
the conversation history. The relay SHALL explain the physician-approved plan
and SHALL NOT introduce clinical recommendations beyond it; questions the plan
does not cover SHALL receive a deferral to the physician. A message raising a
new complaint SHALL transition the conversation to `INTAKE` and be handled as
an intake turn.

#### Scenario: The agent explains the delivered plan

**Given** a conversation in `PLAN_DELIVERED` with a delivered guidance
recommendation
**When** the patient asks a clarifying question about that plan
**Then** the runtime replies with an explanation grounded in the delivered
content
**And** the reply introduces no clinical guidance absent from the delivered
content

#### Scenario: Questions beyond the plan are deferred

**Given** a conversation in `PLAN_DELIVERED`
**When** the patient asks a question the delivered content does not answer
**Then** the reply defers the question to the physician rather than
speculating

#### Scenario: A new complaint reopens intake

**Given** a conversation in `PLAN_DELIVERED`
**When** the patient reports a new medical complaint
**Then** the conversation's care phase becomes `INTAKE`
**And** the runtime handles the message as an interview turn

---

### Requirement: Rejection Revision Loop

When a recommendation is rejected, the AI Agent Runtime SHALL return the
conversation to `INTAKE` and, on the next turn, SHALL incorporate the
physician's rejection reason as reviewer guidance — gathering the missing
information from the patient and drafting a new recommendation. The rejection
reason SHALL NOT be shown to the patient verbatim.

#### Scenario: A rejection resumes the interview toward a revision

**Given** a conversation whose recommendation was rejected with reason "ask
about current medications"
**When** the patient sends their next message
**Then** the runtime runs an interview turn whose model context includes the
rejection reason as guidance
**And** the interview can conclude in a new recommendation in `PENDING_REVIEW`

#### Scenario: The rejection reason is not leaked to the patient

**Given** a rejected recommendation with a stored rejection reason
**When** the runtime delivers any subsequent patient-facing message
**Then** the message does not contain the rejection reason text verbatim

---

### Requirement: Red-Flag Triage

In `INTAKE`, the AI Agent Runtime SHALL screen each patient message for
emergency presentations before running the interview turn. A message
classified as emergent SHALL produce an immediate fixed-text
emergency-referral assistant message, an urgent physician notification, and an
audit event, and SHALL suppress the normal interview turn. If the triage
classification fails or is unparseable, the runtime SHALL proceed with the
normal interview turn and write an `ai_interaction_failed` audit event.

#### Scenario: An emergent message short-circuits the interview

**Given** a conversation in `INTAKE`
**When** the patient describes an emergency presentation and triage classifies
it emergent
**Then** the patient immediately receives the fixed emergency-referral message
**And** physicians receive an urgent notification
**And** no ordinary interview turn runs for that message

#### Scenario: Triage failure fails open to the interview

**Given** the triage classification call errors or returns unparseable output
**When** the runtime processes the patient message
**Then** the normal interview turn proceeds
**And** an `ai_interaction_failed` audit event records the triage failure

