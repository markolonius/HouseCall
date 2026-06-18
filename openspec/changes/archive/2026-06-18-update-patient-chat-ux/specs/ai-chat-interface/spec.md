# Specification: AI Chat Interface

## ADDED Requirements

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
- **THEN** a new conversation is created automatically using the default provider
- **AND** the chat screen opens on that empty conversation ready for input

### Requirement: Access profile from the chat toolbar

The patient SHALL reach profile actions (about, logout) from a profile control
in the top-right of the chat toolbar. There SHALL be no bottom tab bar.

#### Scenario: Patient opens profile from chat

- **GIVEN** the patient is on the chat screen
- **WHEN** the patient taps the profile control in the top-right of the toolbar
- **THEN** the profile surface is presented with account info and a logout action
- **AND** no AI/LLM provider configuration is shown anywhere in the profile

### Requirement: Render assistant messages as Markdown

Assistant message content SHALL be rendered as Markdown so headings, bold,
italic, lists, inline code, code blocks, and links display formatted.

#### Scenario: Assistant returns formatted guidance

- **GIVEN** the assistant returns a response containing a heading, a bulleted list, and bold text
- **WHEN** the message is displayed in the chat
- **THEN** the heading, list, and bold text render as formatted Markdown
- **AND** user messages continue to render as plain text
- **AND** VoiceOver reads the formatted content without exposing markup symbols

## MODIFIED Requirements

### Requirement: Stream AI responses in real-time

AI responses SHALL stream token-by-token to the user interface, with the
visible message bubble updating incrementally as each Server-Sent Events chunk
arrives, providing immediate feedback and reducing perceived latency.

#### Scenario: Long AI response streams smoothly

- **GIVEN** the user asks "What could cause chronic fatigue?"
- **WHEN** the AI generates a 500-token response
- **THEN** tokens appear incrementally in the message bubble as chunks arrive
- **AND** the scroll view auto-scrolls to keep the latest text visible
- **AND** the UI remains responsive (60fps) during streaming
- **AND** the user can read earlier parts of the response while it completes

#### Scenario: Streamed text updates before completion

- **GIVEN** the assistant has begun streaming a response
- **WHEN** the first SSE chunks have arrived but the stream is not complete
- **THEN** the partial text is already visible in the bubble
- **AND** the bubble continues to update as further chunks arrive
- **AND** the input remains disabled until the stream completes

#### Scenario: Streaming is interrupted by network loss

- **GIVEN** the AI is streaming a response (50% complete)
- **WHEN** the network connection is lost
- **THEN** the partial response remains visible in the chat
- **AND** an error indicator shows "Connection lost"
- **AND** a "Retry" button appears below the partial message
- **AND** tapping Retry resends the user's last message

### Requirement: Display real-time chat conversation

Users SHALL be able to view a real-time chat conversation with the AI health
assistant, displaying both user messages and AI responses in a familiar
messaging interface, with assistant responses rendered as Markdown.

#### Scenario: User sends message and receives streaming response

- **GIVEN** the user is authenticated and on the chat screen
- **WHEN** the user types "I have a headache and fever" and taps Send
- **THEN** the message appears immediately in the chat as a user bubble
- **AND** an AI response begins streaming token-by-token within 2 seconds
- **AND** a typing indicator shows while the AI is generating the response
- **AND** the completed AI response is fully visible and Markdown-formatted

#### Scenario: User views conversation history

- **GIVEN** the user has an existing conversation with 10 messages
- **WHEN** the user opens the conversation
- **THEN** all 10 messages are displayed in chronological order
- **AND** user messages are right-aligned in blue bubbles
- **AND** AI messages are left-aligned in gray bubbles
- **AND** each message shows a timestamp

## REMOVED Requirements

### Requirement: Provide conversation list view

**Reason**: The patient now launches directly into a single chat; a multi-
conversation list and "New Chat" entry point are removed from the consumer UX.

**Migration**: Replaced by "Launch directly into a chat after login". Existing
conversations remain in Core Data; the most-recent one is opened on login.

### Requirement: Support LLM provider selection

**Reason**: Provider choice is no longer a patient-facing concern. The app uses
a single hardcoded default provider.

**Migration**: Replaced by the hardcoded default provider requirement in
`llm-provider-integration`. The in-chat picker and the provider-switch system
message are removed.
