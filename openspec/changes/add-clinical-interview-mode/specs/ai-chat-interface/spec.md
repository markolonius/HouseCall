# ai-chat-interface (delta)

## ADDED Requirements

### Requirement: Conduct a clinical history-taking interview

The assistant SHALL conduct the conversation as a focused clinical history,
asking one question per turn and keeping each gathering turn brief, rather than
returning long multi-topic explanations.

#### Scenario: Assistant asks one focused question per turn

- **GIVEN** the user is in a chat and sends "I've had a headache for two days"
- **WHEN** the assistant responds
- **THEN** the response is at most a brief acknowledgment plus a single question
- **AND** the response does not exceed roughly two short sentences before the question
- **AND** the question targets the next relevant history detail (e.g. onset, severity, or location)

#### Scenario: Interview narrows from open to focused questions

- **GIVEN** the user has answered an initial open-ended question
- **WHEN** the assistant continues the interview
- **THEN** subsequent questions become more focused to characterize the complaint
- **AND** the assistant does not present a block of differential explanations

#### Scenario: Emergency red flag interrupts the interview

- **GIVEN** the user reports crushing chest pain and shortness of breath
- **WHEN** the assistant responds
- **THEN** the assistant advises seeking immediate emergency care
- **AND** does not continue routine history questions before that advice

### Requirement: Summarize and advise after the interview

The assistant SHALL be able to produce a concise summary of the gathered
history together with preliminary, non-diagnostic guidance and triage/red-flag
advice, including the standard professional-care disclaimer.

#### Scenario: Summary turn produces structured guidance

- **GIVEN** a conversation with several answered history questions
- **WHEN** the patient requests a summary
- **THEN** the assistant returns a concise summary of the reported history
- **AND** preliminary non-diagnostic guidance and when to seek care
- **AND** a statement that this is not a substitute for professional medical advice

### Requirement: Offer a summarize-now action

The chat interface SHALL provide a control that lets the patient end the
interview and request the assistant's summary.

#### Scenario: Summarize control availability

- **GIVEN** the patient has sent at least one message and no response is streaming
- **WHEN** the chat screen is displayed
- **THEN** a "Summarize" control is enabled
- **WHEN** there are no user messages yet, or a response is currently streaming
- **THEN** the "Summarize" control is disabled

#### Scenario: Tapping summarize requests the closing turn

- **GIVEN** the summarize control is enabled
- **WHEN** the patient taps it
- **THEN** the assistant produces a summary turn as its next response
