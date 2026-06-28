# llm-provider-integration (delta)

## ADDED Requirements

### Requirement: Use a clinical history-taking system prompt

The system prompt injected into every conversation SHALL instruct the model to
act as a clinician taking a focused history — one question per turn, brief
turns, an OPQRST-based history structure, open-then-focused questioning, and
emergency red-flag escalation — while retaining the non-diagnosis and
professional-care safety constraints. The prompt SHALL include a short few-shot
exemplar demonstrating the interview cadence.

#### Scenario: Interview prompt is sent as the leading system message

- **GIVEN** a conversation in the gathering phase
- **WHEN** the chat context is built for a provider request
- **THEN** the leading system message is the clinical interview prompt
- **AND** it instructs one question per turn and short responses
- **AND** it retains the no-diagnosis and professional-care safety constraints

#### Scenario: Summary prompt is sent for the closing turn

- **GIVEN** a conversation transitioning to the summary phase
- **WHEN** the chat context is built for that turn
- **THEN** the leading system message is the summary prompt
- **AND** it instructs a concise summary plus preliminary non-diagnostic guidance

### Requirement: Constrain interview-turn response length

The system SHALL apply a small per-request maximum-token budget to gathering
turns and a larger budget to the summary turn, without mutating the stored
provider configuration.

#### Scenario: Gathering turn uses a small token budget

- **GIVEN** a conversation in the gathering phase
- **WHEN** a provider request is issued for the next assistant turn
- **THEN** the request uses a small max-tokens budget to keep the turn short
- **AND** the stored provider configuration is unchanged

#### Scenario: Summary turn uses a larger token budget

- **GIVEN** a conversation in the summary phase
- **WHEN** the provider request is issued
- **THEN** the request uses a larger max-tokens budget sufficient for the summary
