# ai-agent-runtime (delta)

## MODIFIED Requirements

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

## ADDED Requirements

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
