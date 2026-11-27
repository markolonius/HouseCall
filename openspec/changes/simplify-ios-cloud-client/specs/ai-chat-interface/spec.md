# ai-chat-interface (delta)

## REMOVED Requirements

### Requirement: Stream AI responses in real-time
**Reason**: The app no longer streams from a model. Assistant and agent messages are persisted server-side and arrive whole over message sync and WebSocket.
**Migration**: None. The typing indicator remains for the period between sending a message and receiving the agent's reply.

## MODIFIED Requirements

### Requirement: Launch directly into a chat after login

After authentication, the patient SHALL be taken straight into a chat
conversation without an intermediate conversation list or a "New Chat" step.

#### Scenario: Returning patient lands in most-recent conversation

- **GIVEN** the patient has at least one existing conversation
- **WHEN** the patient finishes logging in
- **THEN** the chat screen opens directly on the most-recently-updated conversation
- **AND** no conversation list or "New Chat" button is shown

#### Scenario: First-time patient gets a conversation created

- **GIVEN** the patient has no existing conversations
- **WHEN** the patient finishes logging in
- **THEN** a new conversation is created automatically and registered with the Core API
- **AND** the chat screen opens on that empty conversation ready for input
- **AND** no model provider is selected or stored for it
