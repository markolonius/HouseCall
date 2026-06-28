# core-api (delta)

## ADDED Requirements

### Requirement: Agent Interview Message Delivery

The Core API SHALL provide a channel for the AI Agent Runtime to deliver a
non-clinical interview question to the originating patient: the question SHALL be
persisted as an assistant message on the conversation and pushed to the patient's
live WebSocket connection when present. Interview questions SHALL NOT pass through
the recommendation review lifecycle.

#### Scenario: Interview question reaches the patient

- **GIVEN** the agent runtime generates an interview question for a conversation
- **WHEN** the Core API delivers it
- **THEN** the question is persisted as an assistant message on that conversation
- **AND** it is pushed to the patient's WebSocket if connected
- **AND** no recommendation row is created for the question

#### Scenario: Offline patient receives the question on reconnect

- **GIVEN** the patient is offline when an interview question is delivered
- **WHEN** the patient reconnects and syncs the conversation
- **THEN** the persisted assistant message is included in the message history

### Requirement: SOAP Note Recommendation Payload

The Core API SHALL accept and persist Recommendations with `payload_type` =
`soap_note` whose payload contains structured Subjective, Objective, Assessment,
and Plan fields, scoped to the owning tenant like every other recommendation.

#### Scenario: A soap_note recommendation is tenant-scoped

- **GIVEN** a `soap_note` recommendation drafted for a patient in tenant A
- **WHEN** it is persisted and later queried
- **THEN** it is only ever returned within tenant A's scope
- **AND** its payload exposes the Subjective, Objective, Assessment, and Plan fields
