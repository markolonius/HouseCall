# Specification: AI Chat Interface

## ADDED Requirements

### Requirement: Display real-time chat conversation

Users shall be able to view a real-time chat conversation with the AI health assistant, displaying both user messages and AI responses in a familiar messaging interface.

#### Scenario: User sends message and receives streaming response

**Given** the user is authenticated and on the chat screen
**When** the user types "I have a headache and fever" and taps Send
**Then** the message appears immediately in the chat as a user bubble
**And** an AI response begins streaming token-by-token within 2 seconds
**And** a typing indicator shows while the AI is generating the response
**And** the completed AI response is fully visible in the chat

#### Scenario: User views conversation history

**Given** the user has an existing conversation with 10 messages
**When** the user opens the conversation
**Then** all 10 messages are displayed in chronological order
**And** user messages are right-aligned in blue bubbles
**And** AI messages are left-aligned in gray bubbles
**And** each message shows a timestamp

---

### Requirement: Stream AI responses in real-time

AI responses shall stream token-by-token to the user interface, providing immediate feedback and reducing perceived latency for long responses.

#### Scenario: Long AI response streams smoothly

**Given** the user asks "What could cause chronic fatigue?"
**When** the AI generates a 500-token response
**Then** tokens appear incrementally in the message bubble
**And** the scroll view auto-scrolls to keep the latest text visible
**And** the UI remains responsive (60fps) during streaming
**And** the user can read earlier parts of the response while it completes

#### Scenario: Streaming is interrupted by network loss

**Given** the AI is streaming a response (50% complete)
**When** the network connection is lost
**Then** the partial response remains visible in the chat
**And** an error indicator shows "Connection lost"
**And** a "Retry" button appears below the partial message
**And** tapping Retry resends the user's last message

---

### Requirement: Enable message input and sending

Users shall be able to compose and send text messages to the AI assistant through an intuitive input interface.

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

### Requirement: Provide conversation list view

Users shall be able to view a list of all their conversations and create new conversations with the AI assistant.

#### Scenario: User views all conversations

**Given** the user has 3 conversations
**When** the user navigates to the Conversations screen
**Then** all 3 conversations are listed in reverse chronological order (newest first)
**And** each conversation shows a title (first message preview)
**And** each conversation shows the last message timestamp
**And** each conversation shows the LLM provider used (icon/badge)

#### Scenario: User creates a new conversation

**Given** the user is on the Conversations list screen
**When** the user taps the "+ New Chat" button
**Then** a new conversation is created
**And** the chat screen opens for the new conversation
**And** the default LLM provider is selected
**And** the conversation is empty (no messages)

#### Scenario: User opens an existing conversation

**Given** the user has a conversation with 5 messages
**When** the user taps the conversation in the list
**Then** the chat screen opens
**And** all 5 messages are displayed
**And** the conversation title appears in the navigation bar
**And** the user can send new messages to continue the conversation

---

### Requirement: Support LLM provider selection

Users shall be able to view and select which LLM provider to use for each conversation.

#### Scenario: User views current provider

**Given** the user is in an active conversation using OpenAI
**When** the user views the conversation settings
**Then** "OpenAI (GPT-4)" is displayed as the current provider
**And** a badge/icon indicates the provider on the chat screen

#### Scenario: User switches provider mid-conversation

**Given** the user has an ongoing conversation with 3 messages using OpenAI
**When** the user switches to Anthropic Claude in settings
**Then** subsequent AI responses use Claude API
**And** previous messages remain unchanged
**And** a system message indicates "Provider switched to Claude"
**And** conversation context (message history) is maintained

---

### Requirement: Display error states gracefully

The chat interface shall display clear, actionable error messages when issues occur, without exposing sensitive system information.

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

All patient health information displayed in the chat interface shall be protected according to HIPAA requirements.

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
