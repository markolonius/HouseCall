# Implementation Tasks: AI Chat Interface

## Phase 1: Core Data Models & Persistence (Foundation) ✅ COMPLETED

### Task 1.1: Create Core Data entities ✅
- [x] Add Conversation entity to `HouseCall.xcdatamodeld`
  - [x] Add attributes: id (UUID), userId (UUID), encryptedTitle (Binary Data), createdAt (Date), updatedAt (Date), isActive (Boolean), llmProvider (String)
  - [x] Add relationship: messages (one-to-many with Message)
- [x] Add Message entity to `HouseCall.xcdatamodeld`
  - [x] Add attributes: id (UUID), conversationId (UUID), role (String), encryptedContent (Binary Data), timestamp (Date), tokenCount (Int32), streamingComplete (Boolean)
  - [x] Add relationship: conversation (many-to-one with Conversation)
- [x] Generate NSManagedObject subclasses for both entities (automatic code generation)
- [x] Verify Core Data model compiles without errors

**Validation**: ✅ Core Data model updated successfully with both entities

**Commit**: `cd21962` - Implement Phase 1: Core Data models and persistence layer for AI chat

---

### Task 1.2: Create Conversation repository ✅
- [x] Create `ConversationRepository.swift` protocol in `Core/Persistence/`
- [x] Define CRUD operations:
  - [x] `createConversation(userId: UUID, provider: LLMProviderType, title: String?) throws -> Conversation`
  - [x] `fetchConversations(userId: UUID) throws -> [Conversation]`
  - [x] `fetchConversation(id: UUID) throws -> Conversation?`
  - [x] `updateConversationTitle(id: UUID, title: String) throws`
  - [x] `updateConversationTimestamp(id: UUID, timestamp: Date) throws`
  - [x] `updateConversationProvider(id: UUID, provider: LLMProviderType) throws`
  - [x] `deleteConversation(id: UUID) throws`
  - [x] `decryptConversationTitle(_ conversation: Conversation) throws -> String`
- [x] Create `CoreDataConversationRepository.swift` implementation
- [x] Integrate with `EncryptionManager` for title encryption/decryption
- [x] Add audit logging for all operations

**Validation**: ✅ 18 unit tests created and pass for all CRUD operations with encryption

**Files**: `ConversationRepository.swift` (127 lines), `CoreDataConversationRepository.swift` (221 lines)

---

### Task 1.3: Create Message repository ✅
- [x] Create `MessageRepository.swift` protocol in `Core/Persistence/`
- [x] Define operations:
  - [x] `createMessage(conversationId: UUID, role: MessageRole, content: String, streamingComplete: Bool) throws -> Message`
  - [x] `fetchMessages(conversationId: UUID, limit: Int, offset: Int) throws -> [Message]`
  - [x] `fetchAllMessages(conversationId: UUID) throws -> [Message]`
  - [x] `fetchMessage(id: UUID) throws -> Message?`
  - [x] `updateMessageContent(id: UUID, content: String, complete: Bool, tokenCount: Int32?) throws`
  - [x] `deleteMessages(conversationId: UUID) throws`
  - [x] `deleteMessage(id: UUID) throws`
  - [x] `decryptMessageContent(_ message: Message) throws -> String`
  - [x] `getUserId(for conversationId: UUID) throws -> UUID`
- [x] Create `CoreDataMessageRepository.swift` implementation
- [x] Implement encryption/decryption for message content
- [x] Add pagination support (limit/offset)
- [x] Add streaming message update support

**Validation**: ✅ 20 unit tests created and pass for message persistence with encryption, pagination, and streaming

**Files**: `MessageRepository.swift` (149 lines), `CoreDataMessageRepository.swift` (268 lines)

**Tests**: `ConversationRepositoryTests.swift` (334 lines), `MessageRepositoryTests.swift` (404 lines)

---

**Phase 1 Summary**:
- ✅ All Core Data entities created with proper encryption fields
- ✅ Repository protocols and implementations complete
- ✅ 38 comprehensive unit tests passing
- ✅ Audit logging extended with conversation/message/AI event types
- ✅ User-specific encryption for all PHI (titles and content)
- ✅ HIPAA compliance maintained throughout

---

## Phase 2: LLM Provider Layer (API Integration)

### Task 2.1: Define LLM Provider protocol
- [x] Create `LLMProvider.swift` protocol in `Core/Services/`
- [x] Define protocol methods:
  - [x] `streamCompletion(messages:onChunk:onComplete:) async throws`
  - [x] `cancelStreaming()`
  - [x] Property: `providerType: LLMProviderType`
  - [x] Property: `isConfigured: Bool`
- [x] Create supporting types:
  - [x] `LLMProviderType` enum (openai, claude, custom)
  - [x] `ChatMessage` struct (role, content)
  - [x] `MessageRole` enum (system, user, assistant)
  - [x] `LLMError` enum (authentication, network, rateLimit, timeout, etc.)

**Validation**: ✅ Protocol compiles, types are well-defined

---

### Task 2.2: Implement OpenAI provider
- [x] Create `OpenAIProvider.swift` in `Core/Services/LLMProviders/`
- [x] Implement `LLMProvider` protocol
- [x] Add OpenAI-specific configuration:
  - [x] API key retrieval from KeychainManager
  - [x] Model selection (gpt-4, gpt-3.5-turbo)
  - [x] Base URL: `https://api.openai.com/v1/chat/completions`
- [x] Implement SSE streaming:
  - [x] Create `SSEParser.swift` to parse Server-Sent Events
  - [x] Handle `data:` lines and `[DONE]` marker
  - [x] Extract token deltas from JSON chunks
- [x] Add error handling:
  - [x] Parse OpenAI error responses
  - [x] Handle rate limiting (HTTP 429)
  - [x] Implement retry logic with exponential backoff

**Validation**: ✅ Unit tests mock OpenAI API, verify streaming parsing, error handling

---

### Task 2.3: Implement Anthropic Claude provider
- [x] Create `ClaudeProvider.swift` in `Core/Services/LLMProviders/`
- [x] Implement `LLMProvider` protocol
- [x] Add Claude-specific configuration:
  - [x] API key from Keychain
  - [x] Headers: `x-api-key`, `anthropic-version: 2023-06-01`
  - [x] Base URL: `https://api.anthropic.com/v1/messages`
- [x] Implement SSE streaming for Claude format
- [x] Handle Claude-specific error codes
- [x] Add retry logic

**Validation**: ✅ Unit tests verify Claude API compatibility, streaming works

---

### Task 2.4: Implement Custom provider support
- [x] Create `CustomProvider.swift` in `Core/Services/LLMProviders/`
- [x] Implement OpenAI-compatible endpoint support
- [x] Add configuration:
  - [x] Custom base URL (user-provided)
  - [x] Optional API key
  - [x] Model selection
- [x] Handle various self-hosted formats (Ollama, llama.cpp, etc.)
- [x] Test with local Ollama instance if available

**Validation**: ✅ Integration test with Ollama or mock server verifies compatibility

---

### Task 2.5: Create LLM Provider configuration manager
- [x] Create `LLMProviderConfig.swift` struct in `Core/Services/`
- [x] Define configuration storage:
  - [x] Provider type
  - [x] Model name
  - [x] System prompt
  - [x] Temperature, max_tokens
- [x] Store API keys in KeychainManager
- [x] Store non-sensitive config in UserDefaults
- [x] Implement provider switching logic

**Validation**: ✅ Configuration persists across app launches, API keys stored securely

---

## Phase 3: AI Conversation Service (Business Logic) ✅ COMPLETED

### Task 3.1: Create AIConversationService ✅
- [x] Create `AIConversationService.swift` in `Core/Services/`
- [x] Make it `ObservableObject` for SwiftUI integration
- [x] Inject dependencies:
  - [x] ConversationRepository
  - [x] MessageRepository
  - [x] LLM Provider instances (OpenAI, Claude, Custom)
  - [x] AuditLogger
- [x] Implement methods:
  - [x] `sendMessage(conversationId: UUID, content: String) async throws`
  - [x] `createConversation(provider: LLMProviderType) async throws -> Conversation`
  - [x] `switchProvider(conversationId: UUID, to: LLMProviderType) async throws`

**Validation**: ✅ Service layer unit tests created (20+ test cases)

**Files**: `AIConversationService.swift` (526 lines)

---

### Task 3.2: Implement streaming message handling ✅
- [x] In `AIConversationService.sendMessage()`:
  - [x] Save user message to Core Data (encrypted)
  - [x] Create placeholder AI message (streamingComplete: false)
  - [x] Call `LLMProvider.streamCompletion()`
  - [x] Update AI message incrementally as chunks arrive
  - [x] Mark streaming complete when [DONE] received
- [x] Publish streaming updates to SwiftUI via `@Published` properties
- [x] Handle streaming interruptions (network loss, cancellation)

**Validation**: ✅ Streaming implementation complete with proper error handling

---

### Task 3.3: Add audit logging integration ✅
- [x] Log conversation creation events
- [x] Log message creation events (no content in logs)
- [x] Log AI interaction events:
  - [x] Provider used
  - [x] Token count
  - [x] Success/failure
  - [x] Timestamp
- [x] Log provider switching events
- [x] Ensure no PHI in any log entries

**Validation**: ✅ All audit logging integrated, no PHI exposure

**Tests**: `AIConversationServiceTests.swift` (428 lines, 20+ tests)

---

**Phase 3 Summary**:
- ✅ AIConversationService created as ObservableObject for SwiftUI integration
- ✅ Full streaming message handling with incremental UI updates
- ✅ Comprehensive error handling and user feedback
- ✅ All operations audit logged for HIPAA compliance
- ✅ 20+ unit tests covering all service methods
- ✅ Proper dependency injection for testability
- ✅ Support for provider switching mid-conversation
- ✅ Conversation and message lifecycle management

---

## Phase 4: SwiftUI Chat Interface (UI Layer) ✅ COMPLETED

### Task 4.1: Create chat view components ✅
- [x] Create `ChatView.swift` in `Features/Conversation/Views/`
- [x] Implement scrollable message list:
  - [x] Use `ScrollViewReader` for auto-scroll
  - [x] Display message bubbles (user + AI)
  - [x] Show timestamps
  - [x] Show typing indicator during streaming
- [x] Create `MessageBubbleView.swift`:
  - [x] User messages: right-aligned, blue background
  - [x] AI messages: left-aligned, gray background
  - [x] Support multi-line text
  - [x] Show timestamp on tap gesture

**Validation**: ✅ SwiftUI previews created for all components

**Files**: `ChatView.swift` (294 lines), `MessageBubbleView.swift` (188 lines)

---

### Task 4.2: Create message input component ✅
- [x] Add text input field at bottom of ChatView
- [x] Add Send button (enabled when text is non-empty)
- [x] Add Cancel/Clear button
- [x] Disable input while AI is streaming
- [x] Show "AI is responding..." label during streaming
- [x] Clear input field after sending

**Validation**: ✅ Input area integrated into ChatView with proper state management

---

### Task 4.3: Implement streaming UI updates ✅
- [x] Bind ChatView to ConversationViewModel's @Published messages
- [x] Update message bubble text as chunks arrive
- [x] Auto-scroll to bottom during streaming
- [x] Show typing indicator animation
- [x] Ensure 60fps performance during updates

**Validation**: ✅ Streaming updates implemented via Combine publishers, auto-scroll working

---

### Task 4.4: Create conversation list view ✅
- [x] Create `ConversationListView.swift` in `Features/Conversation/Views/`
- [x] Display list of conversations:
  - [x] Show conversation title (encrypted, decrypted for display)
  - [x] Show last message timestamp (relative format)
  - [x] Show LLM provider badge/icon
  - [x] Sort by updatedAt descending
- [x] Add "+ New Chat" button (toolbar and empty state)
- [x] Implement navigation to ChatView on tap
- [x] Add swipe-to-delete gesture

**Validation**: ✅ ConversationListView with embedded ConversationListViewModel

**Files**: `ConversationListView.swift` (322 lines)

---

### Task 4.5: Create ConversationViewModel ✅
- [x] Create `ConversationViewModel.swift` in `Features/Conversation/ViewModels/`
- [x] Make it `ObservableObject`
- [x] Inject `AIConversationService`
- [x] Add @Published properties:
  - [x] `messages: [Message]`
  - [x] `isStreaming: Bool`
  - [x] `currentConversation: Conversation?`
  - [x] `errorMessage: String?`
  - [x] `streamingText: String`
  - [x] `streamingMessageId: UUID?`
- [x] Implement methods:
  - [x] `loadConversation(id: UUID)`
  - [x] `sendMessage(content: String)`
  - [x] `retryLastMessage()`
  - [x] `clearError()`
  - [x] `switchProvider(to: LLMProviderType)`
- [x] Handle errors and display user-friendly messages
- [x] Setup Combine observers for AIConversationService

**Validation**: ✅ ViewModel complete with full error handling and state management

**Files**: `ConversationViewModel.swift` (208 lines)

---

### Task 4.6: Update app navigation ✅
- [x] Replace MainAppView placeholder with TabView
- [x] Integrate ConversationListView in Chat tab
- [x] Create Profile tab with user info and logout
- [x] Pass CoreData context and repositories
- [x] Maintain authentication flow

**Validation**: ✅ HouseCallApp.swift updated, tab navigation working

---

**Phase 4 Summary**:
- ✅ All UI components created with proper SwiftUI patterns
- ✅ MVVM architecture maintained throughout
- ✅ Combine-based reactive state management
- ✅ Streaming UI updates with auto-scroll
- ✅ Error handling with user-friendly messages
- ✅ Tab-based navigation integrated
- ✅ SwiftUI previews for all components
- ✅ Encrypted message display
- ✅ Provider badges and icons
- ✅ Audit logging integrated

**Commit**: `0985ecb` - Implement Phase 4: SwiftUI Chat Interface (UI Layer)

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

## Phase 6: Provider Configuration UI ✅ COMPLETED

### Task 6.1: Create provider settings view ✅
- [x] Create `LLMProviderSettingsView.swift` in `Features/Settings/Views/`
- [x] Add provider selection picker (OpenAI, Claude, Custom)
- [x] Add secure API key input fields (masked)
- [x] Add model selection dropdown per provider
- [x] Add custom endpoint URL field (for Custom provider)
- [x] Save configuration to KeychainManager

**Validation**: ✅ Settings persist, API keys stored securely in Keychain

**Files**: `LLMProviderSettingsView.swift` (392 lines), `LLMProviderSettingsViewModel.swift` (282 lines)

---

### Task 6.2: Add provider switching in conversation ✅
- [x] Add provider selector in ChatView toolbar
- [x] Allow switching mid-conversation
- [x] Maintain conversation context on switch
- [x] Display system message indicating switch

**Validation**: ✅ Provider switching implemented with context preservation and system messages

**Files**: Updated `ChatView.swift`, `MessageBubbleView.swift`

---

**Phase 6 Summary**:
- ✅ Comprehensive settings UI with provider selection and configuration
- ✅ Secure API key storage with masked input fields
- ✅ Model selection for OpenAI (GPT-4, GPT-4-Turbo, GPT-3.5-Turbo) and Claude
- ✅ Custom provider support with configurable endpoint and authentication
- ✅ Temperature and max_tokens sliders with real-time value display
- ✅ Provider switching menu in ChatView toolbar
- ✅ System messages displayed when provider is switched
- ✅ Settings accessible from Profile tab and ChatView menu
- ✅ Configuration persistence via UserDefaults and Keychain
- ✅ "Test Configuration" and "Save Settings" functionality

---

## Phase 7: Security & Compliance ✅ COMPLETED

### Task 7.1: Verify encryption implementation ✅
- [x] Audit all message encryption/decryption calls
- [x] Verify EncryptionManager integration
- [x] Test encryption with different user IDs
- [x] Confirm no plaintext PHI in Core Data database file

**Validation**: ✅ Comprehensive SecurityTests.swift created with 15+ tests verifying:
- Conversation titles encrypted at rest
- Message content encrypted at rest
- Different user IDs produce different ciphertexts
- Tampering detection via AES-256-GCM authentication
- No plaintext PHI in Core Data storage
- User-specific key derivation with HKDF
- Encryption cache management

**Files**: `SecurityTests.swift` (567 lines, 15+ security tests)

---

### Task 7.2: Audit logging review ✅
- [x] Review all audit log entries for completeness
- [x] Verify no PHI in log messages
- [x] Test audit log retrieval
- [x] Confirm timestamps are accurate (millisecond precision)

**Validation**: ✅ Audit logging verified:
- All conversation operations logged (create, access, delete, provider switch)
- All message operations logged without PHI
- All AI interactions logged (start, complete, fail, interrupt)
- Unauthorized access attempts logged
- Timestamps have millisecond precision
- All details encrypted
- No PHI in log messages

**Implementation**: `AuditLogger.swift` (392 lines, 68 event types)

---

### Task 7.3: Screen capture protection ✅
- [x] Implement screenshot detection for iOS
- [x] Add privacy screen for app switcher
- [x] Log screenshot attempts to audit trail
- [x] Display privacy screen overlay on app background

**Validation**: ✅ Screen protection implemented:
- `ScreenProtectionManager` detects screenshots via UIApplication notifications
- Screenshots logged to audit trail with timestamp
- Privacy screen overlay shown in app switcher (inactive/background states)
- Scene phase monitoring in HouseCallApp
- PrivacyScreenView displays secure content when backgrounded

**Files**:
- `ScreenProtectionManager.swift` (171 lines)
- `HouseCallApp.swift` (updated with scene phase handling)
- Tests added to `SecurityTests.swift`

---

### Task 7.4: Session timeout enforcement ✅
- [x] Verify chat requires authentication
- [x] Test auto-logout on 5-minute inactivity
- [x] Confirm session invalidation on background
- [x] Verify re-authentication clears in-memory decrypted data

**Validation**: ✅ Session timeout verified:
- 5-minute timeout (300 seconds) in `UserSession.isExpired`
- Timer checks every 60 seconds for timeout
- Validates session on every user access via `validateSession()`
- Logs timeout events to audit trail
- App lifecycle monitoring (background/foreground transitions)
- Automatic logout on timeout
- Session invalidation clears in-memory data
- EncryptionManager cache cleared on logout

**Implementation**: `AuthenticationService.swift` (session management lines 210-379)

---

**Phase 7 Summary**:
- ✅ All encryption verified with comprehensive tests
- ✅ Audit logging complete and HIPAA-compliant
- ✅ Screen capture protection implemented
- ✅ Session timeout enforcement verified
- ✅ 15+ security tests passing
- ✅ No PHI exposure in logs or error messages
- ✅ Privacy screen for app switcher
- ✅ Screenshot detection and logging
- ✅ All HIPAA compliance requirements met

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
