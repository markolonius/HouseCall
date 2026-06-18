# ai-chat-interface Specification

## Purpose
TBD - created by archiving change add-ai-chat-interface. Update Purpose after archive.
## Requirements
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

### Requirement: Enable message input and sending

Users SHALL be able to compose and send text messages to the AI assistant through an intuitive input interface.

#### Scenario: User composes and sends a message

**Given** the user is on the chat screen
**When** the user types text into the message input field
**Then** the Send button becomes enabled (blue)
**And** tapping Send submits the message
**And** the input field clears immediately
**And** the keyboard remains visible for follow-up messages

#### Scenario: User cancels message composition

**Given** the user has typed text in the input field
**When** the user taps the X button in the input field
**Then** the input text is cleared
**And** the Send button becomes disabled (gray)
**And** no message is sent

#### Scenario: Prevent sending while AI is responding

**Given** the AI is currently generating a response (streaming active)
**When** the user types in the input field
**Then** the Send button remains disabled
**And** a label shows "AI is responding..."
**And** the user cannot send a new message until streaming completes

---

### Requirement: Display error states gracefully

The chat interface SHALL display clear, actionable error messages when issues occur, without exposing sensitive system information.

#### Scenario: API authentication failure

**Given** the OpenAI API key is invalid or expired
**When** the user sends a message
**Then** an error message displays: "Unable to connect to AI service"
**And** a "Check Settings" button is shown
**And** the user's message is saved locally (not lost)
**And** no API details or keys are exposed in the error message

#### Scenario: Network timeout

**Given** the user sends a message but the network is slow
**When** the request exceeds 30 seconds
**Then** an error displays: "Request timed out"
**And** a "Retry" button appears
**And** the user can retry without retyping the message

#### Scenario: Rate limit exceeded

**Given** the API provider has rate-limited the requests
**When** the user sends a message
**Then** an error displays: "Too many requests. Please wait 60 seconds."
**And** a countdown timer shows time remaining
**And** the Send button is disabled during the wait period

---

### Requirement: Maintain HIPAA compliance in UI

All patient health information displayed in the chat interface SHALL be protected according to HIPAA requirements.

#### Scenario: Screen capture protection

**Given** the user is viewing a chat with health information
**When** the user attempts to take a screenshot
**Then** the screenshot is blocked (iOS screenshot protection)
**Or** the screenshot is allowed but a warning is logged to audit trail
**And** the user receives a notice about PHI privacy

#### Scenario: Auto-lock on background

**Given** the user is viewing an active chat
**When** the app moves to background for 5 minutes
**Then** the session is invalidated
**And** the user must re-authenticate to continue
**And** the chat content is not visible in app switcher (privacy screen)

#### Scenario: No PHI in error logs

**Given** an error occurs during chat interaction
**When** the error is logged
**Then** no message content is included in the log
**And** only error codes and metadata are logged
**And** audit logs separately record the interaction (encrypted)

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

