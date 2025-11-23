# Implementation Tasks: AI Chat Interface

## Phase 1: Core Data Models & Persistence (Foundation)

### Task 1.1: Create Core Data entities
- [ ] Add Conversation entity to `HouseCall.xcdatamodeld`
  - [ ] Add attributes: id (UUID), userId (UUID), encryptedTitle (Binary Data), createdAt (Date), updatedAt (Date), isActive (Boolean), llmProvider (String)
  - [ ] Add relationship: messages (one-to-many with Message)
- [ ] Add Message entity to `HouseCall.xcdatamodeld`
  - [ ] Add attributes: id (UUID), conversationId (UUID), role (String), encryptedContent (Binary Data), timestamp (Date), tokenCount (Int32), streamingComplete (Boolean)
  - [ ] Add relationship: conversation (many-to-one with Conversation)
- [ ] Generate NSManagedObject subclasses for both entities
- [ ] Verify Core Data model compiles without errors

**Validation**: Core Data model builds successfully, entities visible in model editor

---

### Task 1.2: Create Conversation repository
- [ ] Create `ConversationRepository.swift` protocol in `Core/Persistence/`
- [ ] Define CRUD operations:
  - [ ] `createConversation(userId: UUID, provider: String) throws -> Conversation`
  - [ ] `fetchConversations(userId: UUID) throws -> [Conversation]`
  - [ ] `fetchConversation(id: UUID) throws -> Conversation?`
  - [ ] `updateConversation(_ conversation: Conversation) throws`
  - [ ] `deleteConversation(id: UUID) throws`
- [ ] Create `CoreDataConversationRepository.swift` implementation
- [ ] Integrate with `EncryptionManager` for title encryption/decryption
- [ ] Add audit logging for all operations

**Validation**: Unit tests pass for all CRUD operations with encryption

---

### Task 1.3: Create Message repository
- [ ] Create `MessageRepository.swift` protocol in `Core/Persistence/`
- [ ] Define operations:
  - [ ] `createMessage(conversationId: UUID, role: String, content: String) throws -> Message`
  - [ ] `fetchMessages(conversationId: UUID, limit: Int, offset: Int) throws -> [Message]`
  - [ ] `updateMessageContent(id: UUID, content: String, complete: Bool) throws`
  - [ ] `deleteMessages(conversationId: UUID) throws`
- [ ] Create `CoreDataMessageRepository.swift` implementation
- [ ] Implement encryption/decryption for message content
- [ ] Add pagination support (limit/offset)

**Validation**: Unit tests verify message persistence with encryption, pagination works correctly

---

## Phase 2: LLM Provider Layer (API Integration)

### Task 2.1: Define LLM Provider protocol
- [ ] Create `LLMProvider.swift` protocol in `Core/Services/`
- [ ] Define protocol methods:
  - [ ] `streamCompletion(messages:onChunk:onComplete:) async throws`
  - [ ] `cancelStreaming()`
  - [ ] Property: `providerType: LLMProviderType`
  - [ ] Property: `isConfigured: Bool`
- [ ] Create supporting types:
  - [ ] `LLMProviderType` enum (openai, claude, custom)
  - [ ] `ChatMessage` struct (role, content)
  - [ ] `MessageRole` enum (system, user, assistant)
  - [ ] `LLMError` enum (authentication, network, rateLimit, timeout, etc.)

**Validation**: Protocol compiles, types are well-defined

---

### Task 2.2: Implement OpenAI provider
- [ ] Create `OpenAIProvider.swift` in `Core/Services/LLMProviders/`
- [ ] Implement `LLMProvider` protocol
- [ ] Add OpenAI-specific configuration:
  - [ ] API key retrieval from KeychainManager
  - [ ] Model selection (gpt-4, gpt-3.5-turbo)
  - [ ] Base URL: `https://api.openai.com/v1/chat/completions`
- [ ] Implement SSE streaming:
  - [ ] Create `SSEParser.swift` to parse Server-Sent Events
  - [ ] Handle `data:` lines and `[DONE]` marker
  - [ ] Extract token deltas from JSON chunks
- [ ] Add error handling:
  - [ ] Parse OpenAI error responses
  - [ ] Handle rate limiting (HTTP 429)
  - [ ] Implement retry logic with exponential backoff

**Validation**: Unit tests mock OpenAI API, verify streaming parsing, error handling

---

### Task 2.3: Implement Anthropic Claude provider
- [ ] Create `ClaudeProvider.swift` in `Core/Services/LLMProviders/`
- [ ] Implement `LLMProvider` protocol
- [ ] Add Claude-specific configuration:
  - [ ] API key from Keychain
  - [ ] Headers: `x-api-key`, `anthropic-version: 2023-06-01`
  - [ ] Base URL: `https://api.anthropic.com/v1/messages`
- [ ] Implement SSE streaming for Claude format
- [ ] Handle Claude-specific error codes
- [ ] Add retry logic

**Validation**: Unit tests verify Claude API compatibility, streaming works

---

### Task 2.4: Implement Custom provider support
- [ ] Create `CustomProvider.swift` in `Core/Services/LLMProviders/`
- [ ] Implement OpenAI-compatible endpoint support
- [ ] Add configuration:
  - [ ] Custom base URL (user-provided)
  - [ ] Optional API key
  - [ ] Model selection
- [ ] Handle various self-hosted formats (Ollama, llama.cpp, etc.)
- [ ] Test with local Ollama instance if available

**Validation**: Integration test with Ollama or mock server verifies compatibility

---

### Task 2.5: Create LLM Provider configuration manager
- [ ] Create `LLMProviderConfig.swift` struct in `Core/Services/`
- [ ] Define configuration storage:
  - [ ] Provider type
  - [ ] Model name
  - [ ] System prompt
  - [ ] Temperature, max_tokens
- [ ] Store API keys in KeychainManager
- [ ] Store non-sensitive config in UserDefaults
- [ ] Implement provider switching logic

**Validation**: Configuration persists across app launches, API keys stored securely

---

## Phase 3: AI Conversation Service (Business Logic)

### Task 3.1: Create AIConversationService
- [ ] Create `AIConversationService.swift` in `Core/Services/`
- [ ] Make it `ObservableObject` for SwiftUI integration
- [ ] Inject dependencies:
  - [ ] ConversationRepository
  - [ ] MessageRepository
  - [ ] LLM Provider instances (OpenAI, Claude, Custom)
  - [ ] AuditLogger
- [ ] Implement methods:
  - [ ] `sendMessage(conversationId: UUID, content: String) async throws`
  - [ ] `createConversation(provider: LLMProviderType) async throws -> Conversation`
  - [ ] `switchProvider(conversationId: UUID, to: LLMProviderType) async throws`

**Validation**: Service layer unit tests verify message flow

---

### Task 3.2: Implement streaming message handling
- [ ] In `AIConversationService.sendMessage()`:
  - [ ] Save user message to Core Data (encrypted)
  - [ ] Create placeholder AI message (streamingComplete: false)
  - [ ] Call `LLMProvider.streamCompletion()`
  - [ ] Update AI message incrementally as chunks arrive
  - [ ] Mark streaming complete when [DONE] received
- [ ] Publish streaming updates to SwiftUI via `@Published` properties
- [ ] Handle streaming interruptions (network loss, cancellation)

**Validation**: Integration test verifies end-to-end streaming with Core Data persistence

---

### Task 3.3: Add audit logging integration
- [ ] Log conversation creation events
- [ ] Log message creation events (no content in logs)
- [ ] Log AI interaction events:
  - [ ] Provider used
  - [ ] Token count
  - [ ] Success/failure
  - [ ] Timestamp
- [ ] Log provider switching events
- [ ] Ensure no PHI in any log entries

**Validation**: Audit logs generated correctly, verified no PHI exposure

---

## Phase 4: SwiftUI Chat Interface (UI Layer)

### Task 4.1: Create chat view components
- [ ] Create `ChatView.swift` in `Features/Conversation/Views/`
- [ ] Implement scrollable message list:
  - [ ] Use `ScrollViewReader` for auto-scroll
  - [ ] Display message bubbles (user + AI)
  - [ ] Show timestamps
  - [ ] Show typing indicator during streaming
- [ ] Create `MessageBubbleView.swift`:
  - [ ] User messages: right-aligned, blue background
  - [ ] AI messages: left-aligned, gray background
  - [ ] Support multi-line text
  - [ ] Show timestamp on long-press

**Validation**: Preview in Xcode shows chat interface correctly

---

### Task 4.2: Create message input component
- [ ] Add text input field at bottom of ChatView
- [ ] Add Send button (enabled when text is non-empty)
- [ ] Add Cancel/Clear button
- [ ] Disable input while AI is streaming
- [ ] Show "AI is responding..." label during streaming
- [ ] Clear input field after sending

**Validation**: UI test verifies input interaction flow

---

### Task 4.3: Implement streaming UI updates
- [ ] Bind ChatView to ConversationViewModel's @Published messages
- [ ] Update message bubble text as chunks arrive
- [ ] Auto-scroll to bottom during streaming
- [ ] Show typing indicator animation
- [ ] Ensure 60fps performance during updates

**Validation**: UI test with mock streaming verifies smooth rendering

---

### Task 4.4: Create conversation list view
- [ ] Create `ConversationListView.swift` in `Features/Conversation/Views/`
- [ ] Display list of conversations:
  - [ ] Show conversation title (encrypted, decrypted for display)
  - [ ] Show last message timestamp
  - [ ] Show LLM provider badge/icon
  - [ ] Sort by updatedAt descending
- [ ] Add "+ New Chat" button
- [ ] Implement navigation to ChatView on tap
- [ ] Add swipe-to-delete gesture

**Validation**: UI displays conversation list, navigation works

---

### Task 4.5: Create ConversationViewModel
- [ ] Create `ConversationViewModel.swift` in `Features/Conversation/ViewModels/`
- [ ] Make it `ObservableObject`
- [ ] Inject `AIConversationService`
- [ ] Add @Published properties:
  - [ ] `messages: [Message]`
  - [ ] `isStreaming: Bool`
  - [ ] `currentConversation: Conversation?`
  - [ ] `errorMessage: String?`
- [ ] Implement methods:
  - [ ] `loadConversation(id: UUID)`
  - [ ] `sendMessage(content: String)`
  - [ ] `createNewConversation()`
- [ ] Handle errors and display user-friendly messages

**Validation**: Unit tests verify ViewModel logic, UI integration test

---

## Phase 5: Error Handling & Edge Cases

### Task 5.1: Implement error UI states
- [ ] Add error banner component to ChatView
- [ ] Display specific error messages:
  - [ ] "Unable to connect to AI service"
  - [ ] "API authentication failed. Check settings."
  - [ ] "Request timed out. Retry?"
  - [ ] "Rate limit exceeded. Wait 60s."
- [ ] Add Retry button for recoverable errors
- [ ] Add Settings navigation for configuration errors

**Validation**: UI tests verify error states display correctly

---

### Task 5.2: Handle network interruptions
- [ ] Detect network loss during streaming
- [ ] Save partial AI response
- [ ] Show "Connection lost" indicator
- [ ] Allow user to retry
- [ ] Queue user messages when offline

**Validation**: Network condition simulation tests verify graceful handling

---

### Task 5.3: Implement timeout handling
- [ ] Add 30-second timeout for all API requests
- [ ] Cancel streaming on timeout
- [ ] Provide retry option
- [ ] Log timeout events to audit trail

**Validation**: Mock slow API responses, verify timeout behavior

---

### Task 5.4: Add rate limiting UI feedback
- [ ] Parse rate limit headers from provider responses
- [ ] Display countdown timer
- [ ] Disable Send button during wait period
- [ ] Auto-retry after wait time

**Validation**: Mock 429 responses, verify UI feedback

---

## Phase 6: Provider Configuration UI

### Task 6.1: Create provider settings view
- [ ] Create `LLMProviderSettingsView.swift` in `Features/Settings/Views/`
- [ ] Add provider selection picker (OpenAI, Claude, Custom)
- [ ] Add secure API key input fields (masked)
- [ ] Add model selection dropdown per provider
- [ ] Add custom endpoint URL field (for Custom provider)
- [ ] Save configuration to KeychainManager

**Validation**: Settings persist, API keys stored securely in Keychain

---

### Task 6.2: Add provider switching in conversation
- [ ] Add provider selector in ChatView toolbar
- [ ] Allow switching mid-conversation
- [ ] Maintain conversation context on switch
- [ ] Display system message indicating switch

**Validation**: UI test verifies provider switching works without data loss

---

## Phase 7: Security & Compliance

### Task 7.1: Verify encryption implementation
- [ ] Audit all message encryption/decryption calls
- [ ] Verify EncryptionManager integration
- [ ] Test encryption with different user IDs
- [ ] Confirm no plaintext PHI in Core Data database file

**Validation**: Security test dumps Core Data file, verifies all PHI encrypted

---

### Task 7.2: Audit logging review
- [ ] Review all audit log entries for completeness
- [ ] Verify no PHI in log messages
- [ ] Test audit log retrieval
- [ ] Confirm timestamps are accurate (millisecond precision)

**Validation**: Audit log review passes HIPAA compliance checklist

---

### Task 7.3: Screen capture protection
- [ ] Implement screenshot blocking for iOS (if supported)
- [ ] Add privacy screen for app switcher
- [ ] Log screenshot attempts to audit trail
- [ ] Display privacy notice on screenshot

**Validation**: Manual testing verifies screenshot protection active

---

### Task 7.4: Session timeout enforcement
- [ ] Verify chat requires authentication
- [ ] Test auto-logout on 5-minute inactivity
- [ ] Confirm session invalidation on background
- [ ] Verify re-authentication clears in-memory decrypted data

**Validation**: Session timeout test passes

---

## Phase 8: Testing & Quality Assurance

### Task 8.1: Write unit tests
- [ ] Test SSEParser with various formats
- [ ] Test each LLMProvider implementation
- [ ] Test ConversationRepository CRUD operations
- [ ] Test MessageRepository encryption
- [ ] Test AIConversationService message flow
- [ ] Achieve >90% coverage for Core layer

**Validation**: All unit tests pass, >90% coverage

---

### Task 8.2: Write integration tests
- [ ] Test end-to-end message flow (user → API → storage → UI)
- [ ] Test provider switching
- [ ] Test streaming interruption and recovery
- [ ] Test offline access to conversations

**Validation**: All integration tests pass

---

### Task 8.3: Write UI tests
- [ ] Test chat message sending
- [ ] Test conversation list navigation
- [ ] Test error state displays
- [ ] Test streaming UI updates
- [ ] Test provider settings workflow

**Validation**: All UI tests pass

---

### Task 8.4: Perform security testing
- [ ] Penetration test API key storage
- [ ] Verify encrypted Core Data storage
- [ ] Test for PHI leaks in logs
- [ ] Verify TLS for all network calls
- [ ] Run OWASP Mobile Security checklist

**Validation**: Security audit passes, no vulnerabilities found

---

## Phase 9: Documentation & Handoff

### Task 9.1: Update CLAUDE.md
- [ ] Document new Chat and Conversation components
- [ ] Add LLM provider architecture to CLAUDE.md
- [ ] Document encryption patterns
- [ ] Add troubleshooting guide

**Validation**: CLAUDE.md review complete

---

### Task 9.2: Create user documentation
- [ ] Write provider setup guide (how to add API keys)
- [ ] Document conversation management (create, delete)
- [ ] Add FAQ for common errors
- [ ] Document HIPAA compliance measures

**Validation**: Documentation review complete

---

### Task 9.3: Archive change proposal
- [ ] Merge specs into `openspec/specs/` directory
- [ ] Move change to `openspec/changes/archive/`
- [ ] Update project.md with new capabilities
- [ ] Run `openspec validate --strict`

**Validation**: OpenSpec validation passes

---

## Estimated Timeline

| Phase | Tasks | Estimated Hours |
|-------|-------|----------------|
| Phase 1: Core Data | 3 tasks | 2-3 hours |
| Phase 2: LLM Providers | 5 tasks | 4-6 hours |
| Phase 3: Service Layer | 3 tasks | 3-4 hours |
| Phase 4: UI Layer | 5 tasks | 6-8 hours |
| Phase 5: Error Handling | 4 tasks | 2-3 hours |
| Phase 6: Settings UI | 2 tasks | 2-3 hours |
| Phase 7: Security & Compliance | 4 tasks | 3-4 hours |
| Phase 8: Testing | 4 tasks | 4-6 hours |
| Phase 9: Documentation | 3 tasks | 2-3 hours |
| **TOTAL** | **33 tasks** | **28-40 hours** |

---

## Dependencies & Prerequisites

**✅ Already Implemented:**
- Authentication system (AuthenticationService)
- Encryption infrastructure (EncryptionManager)
- Keychain storage (KeychainManager)
- Audit logging (AuditLogger)
- Core Data stack (PersistenceController)

**⚠️ Required Before Starting:**
- OpenAI API key (for testing, not hardcoded)
- Anthropic API key (optional, for Claude testing)
- Xcode 15+ installed
- iOS Simulator or physical device for testing

**🔄 Can Be Parallelized:**
- Phases 1-2 can run in parallel (data models + API layer)
- Phases 5-6 can run in parallel (error handling + settings UI)
- Phase 8 (testing) runs continuously throughout development

---

## Success Criteria Checklist

- [ ] Users can create new conversations
- [ ] Users can send messages and receive streaming AI responses
- [ ] Conversation history persists across app sessions
- [ ] All messages are encrypted at rest
- [ ] Three LLM providers supported (OpenAI, Claude, Custom)
- [ ] Provider switching works mid-conversation
- [ ] Error states display user-friendly messages
- [ ] Offline conversation viewing works
- [ ] Audit logs capture all AI interactions
- [ ] 90%+ test coverage for critical paths
- [ ] HIPAA compliance validation passes
- [ ] No hardcoded API keys in codebase
- [ ] Documentation complete
- [ ] Security audit passes
