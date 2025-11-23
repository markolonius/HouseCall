# Specification: Conversation Management

## ADDED Requirements

### Requirement: Create and store conversations securely

Conversations and their messages shall be created, encrypted, and persisted to Core Data with full HIPAA compliance.

#### Scenario: Create new conversation

**Given** an authenticated user with ID "user-123"
**When** the user starts a new chat
**Then** a Conversation entity is created with:
- `id`: unique UUID
- `userId`: "user-123"
- `createdAt`: current timestamp
- `updatedAt`: current timestamp
- `isActive`: true
- `llmProvider`: "openai" (default)
- `title`: empty (will be set after first message)
**And** the conversation is saved to Core Data
**And** an audit log entry is created for conversation creation

#### Scenario: Encrypt conversation title

**Given** a conversation's first user message is "I have chest pain"
**When** the conversation title is set based on this message
**Then** the plaintext title "I have chest pain" is encrypted using AES-256-GCM
**And** the encrypted data is stored in `encryptedTitle` field
**And** the plaintext `title` field is set to empty string
**And** the encryption uses the user's encryption key from EncryptionManager

---

### Requirement: Store messages with encryption

All conversation messages shall be encrypted before storage in Core Data.

#### Scenario: Save user message

**Given** the user sends "I've had a fever for 3 days"
**When** the message is saved to Core Data
**Then** a Message entity is created with:
- `id`: unique UUID
- `conversationId`: (linked to conversation)
- `role`: "user"
- `encryptedContent`: AES-256-GCM encrypted message text
- `timestamp`: current timestamp
- `streamingComplete`: true
- `tokenCount`: 0 (not applicable for user messages)
**And** the message is associated with its Conversation entity
**And** the Core Data context is saved

#### Scenario: Save streaming AI message incrementally

**Given** the AI is streaming a response: "Based on your symptoms..."
**When** the first chunk "Based on" arrives
**Then** a Message entity is created with:
- `role`: "assistant"
- `encryptedContent`: encrypted "Based on"
- `streamingComplete`: false
**When** the next chunk " your symptoms" arrives
**Then** the `encryptedContent` is updated with encrypted "Based on your symptoms"
**And** `streamingComplete` remains false
**When** the [DONE] signal arrives
**Then** `streamingComplete` is set to true
**And** `tokenCount` is set to the total tokens used
**And** the final Core Data save is performed

---

### Requirement: Retrieve and decrypt conversations

Users shall be able to retrieve their conversation history with transparent decryption.

#### Scenario: Fetch all conversations for user

**Given** user "user-123" has 5 conversations in Core Data
**When** the Conversations list view loads
**Then** a Core Data fetch request retrieves all conversations where `userId == "user-123"`
**And** the conversations are sorted by `updatedAt` descending
**And** each conversation's `encryptedTitle` is decrypted to plaintext
**And** the plaintext titles are displayed in the UI

#### Scenario: Fetch messages for a conversation

**Given** a conversation with ID "conv-456" has 20 messages
**When** the user opens the conversation
**Then** a Core Data fetch request retrieves all messages where `conversationId == "conv-456"`
**And** messages are sorted by `timestamp` ascending
**And** each message's `encryptedContent` is decrypted
**And** decrypted messages are displayed in the chat view

---

### Requirement: Update conversation metadata

Conversation metadata (last updated time, title) shall update automatically when new messages are added.

#### Scenario: Update conversation timestamp on new message

**Given** a conversation with `updatedAt` = "2025-11-20T10:00:00Z"
**When** a new message is added at "2025-11-22T15:30:00Z"
**Then** the conversation's `updatedAt` is updated to "2025-11-22T15:30:00Z"
**And** the conversation moves to the top of the list (newest first)

#### Scenario: Set conversation title from first message

**Given** a new conversation with no title
**When** the first user message is "Can you help me understand my blood pressure results?"
**Then** the conversation title is set to the first 50 characters: "Can you help me understand my blood pressure r..."
**And** the title is encrypted and stored in `encryptedTitle`

---

### Requirement: Delete conversations securely

Users shall be able to delete conversations with secure deletion of all associated data.

#### Scenario: Delete single conversation

**Given** a conversation with 10 messages
**When** the user selects "Delete Conversation" and confirms
**Then** all 10 Message entities are deleted from Core Data
**And** the Conversation entity is deleted
**And** the Core Data context is saved
**And** an audit log entry records the deletion:
- Event type: "conversation_deleted"
- Conversation ID: (encrypted)
- Message count: 10

#### Scenario: Prevent deletion of in-progress streaming

**Given** the AI is currently streaming a response to a conversation
**When** the user attempts to delete the conversation
**Then** a warning is displayed: "Cannot delete while AI is responding"
**And** the delete action is blocked
**And** the streaming must complete before deletion is allowed

---

### Requirement: Implement conversation pagination

For conversations with many messages, the system shall implement efficient pagination to avoid memory issues.

#### Scenario: Load initial messages

**Given** a conversation has 200 messages
**When** the user opens the conversation
**Then** only the most recent 50 messages are fetched from Core Data
**And** the chat view displays these 50 messages
**And** a "Load earlier messages" button appears at the top

#### Scenario: Load older messages on demand

**Given** the user has loaded the initial 50 messages
**When** the user scrolls to the top and taps "Load earlier messages"
**Then** the next 50 older messages are fetched
**And** they are inserted at the top of the message list
**And** the scroll position remains stable (no jump)

---

### Requirement: Handle offline conversation access

Users shall be able to view existing conversations even when offline, with graceful handling of offline limitations.

#### Scenario: View conversation history offline

**Given** the device has no network connectivity
**When** the user opens an existing conversation with 30 messages
**Then** all 30 messages are retrieved from local Core Data
**And** all messages are decrypted and displayed normally
**And** no network requests are made

#### Scenario: Attempt to send message offline

**Given** the device has no network connectivity
**When** the user types a message and taps Send
**Then** the message is saved locally to Core Data
**And** an offline indicator displays: "Message saved. Will send when online."
**And** the message is queued for sending when connection restores
**And** the user can continue viewing but not get AI responses

---

### Requirement: Maintain message ordering and integrity

Message timestamps and ordering shall be strictly maintained to preserve conversation flow.

#### Scenario: Preserve message order

**Given** messages are saved with timestamps:
1. User: "Hello" (10:00:00)
2. AI: "Hi there" (10:00:03)
3. User: "I need help" (10:00:10)
4. AI: "How can I assist?" (10:00:15)
**When** the conversation is fetched from Core Data
**Then** messages are returned in exact timestamp order
**And** no messages are skipped or duplicated
**And** the chat view displays them in the correct sequence

#### Scenario: Handle concurrent message saves

**Given** the user sends two messages in quick succession
**When** both messages are saved to Core Data nearly simultaneously
**Then** each message gets a unique, monotonically increasing timestamp
**And** the messages are saved in the correct order
**And** no race condition causes message loss or corruption

---

### Requirement: Integrate with audit logging system

All conversation operations shall be logged to the existing HIPAA-compliant audit trail.

#### Scenario: Log conversation creation

**Given** a user creates a new conversation
**When** the Conversation entity is saved to Core Data
**Then** an audit log entry is created:
- Event type: "conversation_created"
- User ID: (encrypted user UUID)
- Conversation ID: (conversation UUID)
- Provider: "openai"
- Timestamp: ISO 8601 format

#### Scenario: Log message creation

**Given** a user sends a message "I have a cough"
**When** the Message entity is saved
**Then** an audit log entry is created:
- Event type: "message_created"
- User ID: (encrypted)
- Conversation ID: (encrypted)
- Role: "user"
- Token count: 0
**And** the message content is NOT logged (PHI protection)

#### Scenario: Log conversation access

**Given** a user opens a conversation
**When** the conversation view appears
**Then** an audit log entry is created:
- Event type: "conversation_accessed"
- User ID: (encrypted)
- Conversation ID: (encrypted)
- Message count: (number of messages fetched)

---

### Requirement: Support conversation export (future capability placeholder)

The system shall be designed to support future conversation export functionality for patient records.

#### Scenario: Placeholder for FHIR export

**Given** this is a placeholder requirement for future implementation
**When** conversation export is implemented
**Then** conversations can be exported to FHIR DiagnosticReport format
**And** exported data includes:
- Patient identifier
- Conversation timestamp
- Message history (decrypted, formatted)
- AI provider metadata
**And** exports are encrypted before transmission

---

### Requirement: Handle Core Data conflicts gracefully

The system shall handle potential Core Data merge conflicts without data loss.

#### Scenario: Resolve merge conflict on save

**Given** two Core Data contexts are editing the same conversation
**When** both contexts attempt to save simultaneously
**Then** Core Data's merge policy resolves the conflict
**And** the most recent changes take precedence (NSMergeByPropertyObjectTrumpMergePolicy)
**And** no messages are lost
**And** an error log entry is created if conflicts occur

#### Scenario: Recover from save failure

**Given** a Core Data save operation fails due to disk full
**When** the failure is detected
**Then** the error is logged (without PHI in the log message)
**And** the user is notified: "Unable to save message. Please free up storage."
**And** the unsaved message is kept in memory
**And** the user can retry saving after freeing storage
