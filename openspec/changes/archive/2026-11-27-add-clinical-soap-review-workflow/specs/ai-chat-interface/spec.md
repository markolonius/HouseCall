# ai-chat-interface (delta)

## REMOVED Requirements

### Requirement: Offer a summarize-now action

**Reason**: The manual "Summarize" control is replaced by agent-decided interview
completion — the agent determines when enough history is gathered and drafts a
SOAP note for physician review, so the patient no longer triggers summarization.
**Migration**: Remove the Summarize toolbar button and the client `requestSummary()`
path from the cloud flow; no patient-facing replacement control.

## MODIFIED Requirements

### Requirement: Conduct a clinical history-taking interview

The chat interface SHALL display a clinician-style history interview that is
driven by the server-side agent runtime: one question at a time, arriving as
assistant messages, without a patient-triggered summary control.

#### Scenario: Patient receives one interview question at a time

- **GIVEN** the patient is in a chat conducting the history interview
- **WHEN** the patient sends a message
- **THEN** the next assistant message is a single interview question from the agent
- **AND** no "Summarize" control is shown

#### Scenario: Approved note is shown to the patient

- **GIVEN** the agent has drafted a SOAP note and a physician has approved it
- **WHEN** the approved note is delivered
- **THEN** the patient sees the physician-approved plan rendered as a recommendation card
