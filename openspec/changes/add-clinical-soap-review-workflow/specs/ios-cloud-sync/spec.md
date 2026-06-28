# ios-cloud-sync (delta)

## ADDED Requirements

### Requirement: Interview Question Receipt

The iOS client SHALL receive agent interview questions as assistant messages over
the existing message-sync and WebSocket channels and display them in the
conversation, so the server-driven history interview appears as a normal chat
exchange.

#### Scenario: Live interview question is rendered

- **GIVEN** the patient has an open conversation and a live WebSocket connection
- **WHEN** the agent delivers an interview question
- **THEN** the question appears as an assistant message bubble in the chat

#### Scenario: Missed interview question is synced on reconnect

- **GIVEN** an interview question was delivered while the client was offline
- **WHEN** the client reconnects and syncs the conversation
- **THEN** the previously missed question appears in the message history in order
