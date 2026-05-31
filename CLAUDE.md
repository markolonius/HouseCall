<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HouseCall is a HIPAA-compliant SwiftUI iOS healthcare application using Core Data for encrypted persistence. The app provides secure user authentication with biometric support (Face ID/Touch ID), encrypted data storage, comprehensive audit logging, session management for healthcare data protection, and an AI-powered chat interface for patient interaction with health assistants.

## Build and Test Commands

### Building the App
```bash
# Build for iOS Simulator (Debug)
xcodebuild -scheme HouseCall -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build for iOS Simulator (Release)
xcodebuild -scheme HouseCall -configuration Release -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build and run (use Xcode or iOS Simulator)
open HouseCall.xcodeproj  # Then Cmd+R in Xcode
```

### Running Tests
```bash
# Run all tests
xcodebuild test -scheme HouseCall -destination 'platform=iOS Simulator,name=iPhone 15'

# Run unit tests only (HouseCallTests target)
xcodebuild test -scheme HouseCall -only-testing:HouseCallTests -destination 'platform=iOS Simulator,name=iPhone 15'

# Run UI tests only (HouseCallUITests target)
xcodebuild test -scheme HouseCall -only-testing:HouseCallUITests -destination 'platform=iOS Simulator,name=iPhone 15'

# Run a specific test
xcodebuild test -scheme HouseCall -only-testing:HouseCallTests/HouseCallTests/example -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Clean Build
```bash
xcodebuild clean -scheme HouseCall
```

## Architecture

### Authentication System

#### Security Layer (`Core/Security/`)
- **EncryptionManager.swift**: AES-256-GCM encryption with HKDF key derivation
  - User-specific encryption keys derived from master key
  - All PHI (Protected Health Information) encrypted at rest
  - Keychain storage for master encryption key
  - Session-based key caching

- **KeychainManager.swift**: Secure keychain storage
  - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` for HIPAA compliance
  - Master key, session tokens, auth preferences
  - No iCloud sync for PHI security

- **PasswordHasher.swift**: PBKDF2-SHA256 password hashing
  - 600,000 iterations (OWASP recommended minimum)
  - Unique salt per password
  - Constant-time comparison (timing attack prevention)
  - **Note**: Production should use bcrypt (cost factor 12)

- **BiometricAuthManager.swift**: Face ID/Touch ID integration
  - LocalAuthentication framework
  - Healthcare-appropriate authentication prompts
  - Biometric availability detection
  - Graceful fallback to password/passcode

- **AuditLogger.swift**: HIPAA-compliant audit trail (45 CFR § 164.312(b))
  - All authentication events logged
  - Encrypted event details
  - Millisecond-precision timestamps
  - Device ID tracking

#### Data Access Layer (`Core/Persistence/`)
- **UserRepository.swift**: User data access protocol
  - Supports three authentication methods: password, passcode, biometric
  - CRUD operations with encryption integration
  - Automatic audit logging

- **CoreDataUserRepository.swift**: Core Data implementation
  - Encrypted credential storage
  - Email/ID-based user lookup
  - Authentication verification with audit logging

- **Persistence.swift**: HIPAA-compliant Core Data stack
  - NSFileProtectionComplete for encrypted storage
  - No iCloud sync for PHI
  - Proper error handling (no fatalError)
  - Audit logging for persistence errors

#### Business Logic (`Core/Services/`)
- **AuthenticationService.swift**: High-level authentication orchestration
  - User registration (async/await)
  - Multi-method login (password/passcode/biometric)
  - Session management with 5-minute timeout
  - App lifecycle monitoring (background/foreground)
  - ObservableObject for SwiftUI integration

### AI Chat System

#### Conversation Data Layer (`Core/Persistence/`)
- **ConversationRepository.swift**: Conversation data access protocol
  - Create/read/update/delete conversations
  - User-specific conversation queries
  - Title encryption/decryption
  - Provider switching support
  - Automatic audit logging

- **CoreDataConversationRepository.swift**: Core Data implementation
  - Encrypted conversation title storage
  - User ID-based conversation filtering
  - Conversation timestamp management
  - Integration with EncryptionManager

- **MessageRepository.swift**: Message data access protocol
  - Create/read/update/delete messages
  - Pagination support (limit/offset)
  - Streaming message updates
  - Content encryption/decryption
  - User ID retrieval for encryption

- **CoreDataMessageRepository.swift**: Core Data implementation
  - Encrypted message content storage
  - Streaming message update support
  - Efficient pagination queries
  - Conversation relationship management

#### LLM Provider Layer (`Core/Services/LLMProviders/`)
- **LLMProvider.swift**: Provider abstraction protocol
  - `streamCompletion()` for streaming responses
  - `cancelStreaming()` for request cancellation
  - Provider type identification
  - Configuration validation

- **OpenAIProvider.swift**: OpenAI integration
  - GPT-4, GPT-4-Turbo, GPT-3.5-Turbo support
  - Server-Sent Events (SSE) streaming
  - Bearer token authentication
  - Rate limit and error handling
  - Exponential backoff retry logic

- **ClaudeProvider.swift**: Anthropic Claude integration
  - Claude 3.7 Sonnet, Claude 3 Opus/Haiku support
  - Anthropic SSE streaming format
  - API key + version header authentication
  - Claude-specific error handling

- **CustomProvider.swift**: Self-hosted LLM support
  - OpenAI-compatible endpoint support
  - Ollama, llama.cpp, and custom servers
  - Configurable base URL and authentication
  - Flexible model selection

- **SSEParser.swift**: Server-Sent Events parser
  - Streaming chunk extraction
  - Partial chunk buffering
  - Multi-provider format support
  - [DONE] marker detection

- **LLMProviderConfigManager.swift**: Provider configuration
  - API key storage in KeychainManager
  - Model selection per provider
  - Temperature and max_tokens configuration
  - System prompt management
  - Provider switching logic

#### AI Conversation Service (`Core/Services/`)
- **AIConversationService.swift**: High-level conversation orchestration
  - Create conversations with provider selection
  - Send messages with streaming responses
  - Switch providers mid-conversation
  - Incremental message updates
  - Comprehensive error handling
  - Audit logging integration
  - ObservableObject for SwiftUI integration

### UI Layer

#### App Navigation (`HouseCallApp.swift`)
- Conditional navigation based on authentication state:
  - `isAuthenticated == false` → LoginView
  - `isAuthenticated == true` → TabView with Chat and Profile tabs
- Session validation on app launch
- AuthenticationService as environment object
- Screen capture protection with privacy overlay
- Scene phase monitoring for background/foreground states

#### Authentication Views (`Features/Authentication/Views/`)
- **SignUpView.swift**: User registration
  - Real-time validation with visual feedback
  - Password strength indicator (0-5 scale)
  - Healthcare-appropriate messaging
  - Accessibility support

- **LoginView.swift**: User login
  - Email + credential input
  - Biometric toggle (Face ID/Touch ID)
  - Auth method detection

#### Conversation Views (`Features/Conversation/Views/`)
- **ConversationListView.swift**: Conversation list with navigation
  - Displays all user conversations (sorted by updatedAt)
  - Encrypted conversation titles (decrypted for display)
  - Provider badges (OpenAI, Claude, Custom)
  - "New Chat" button in toolbar and empty state
  - Swipe-to-delete gesture
  - Navigation to ChatView on tap
  - Embedded ConversationListViewModel

- **ChatView.swift**: Real-time chat interface
  - Scrollable message list with ScrollViewReader
  - Message bubbles (user: right-aligned blue, AI: left-aligned gray)
  - Auto-scroll to bottom during streaming
  - Typing indicator animation
  - Message input with Send/Clear buttons
  - Provider switcher menu in toolbar
  - Error banner with retry functionality
  - Settings navigation
  - System messages for provider switches

- **MessageBubbleView.swift**: Message display component
  - User messages: right-aligned, blue background
  - AI messages: left-aligned, gray background
  - System messages: centered, italic
  - Multi-line text support
  - Timestamp display on tap
  - VoiceOver accessibility labels

#### Settings Views (`Features/Settings/Views/`)
- **LLMProviderSettingsView.swift**: Provider configuration
  - Provider selection picker (OpenAI, Claude, Custom)
  - Secure API key input (masked text fields)
  - Model selection per provider
  - Custom endpoint URL for self-hosted providers
  - Temperature slider (0.0 - 2.0)
  - Max tokens slider (100 - 4000)
  - Test Configuration button
  - Save Settings button
  - Settings persistence via UserDefaults and Keychain

#### ViewModels
**Authentication** (`Features/Authentication/ViewModels/`)
- **SignUpViewModel**: Registration logic with real-time validation
- **LoginViewModel**: Login orchestration with biometric support

**Conversation** (`Features/Conversation/ViewModels/`)
- **ConversationViewModel**: Chat view state management
  - Load conversations and messages
  - Send messages with streaming handling
  - Provider switching
  - Error handling and retry logic
  - Combine-based reactive updates
  - ObservableObject for SwiftUI integration

**Settings** (`Features/Settings/ViewModels/`)
- **LLMProviderSettingsViewModel**: Provider configuration management
  - API key storage in Keychain
  - Provider configuration persistence
  - Model selection logic
  - Configuration validation
  - Test connection functionality

#### Deprecated (`ContentView.swift`)
- Template view from Xcode project creation
- **Not used in app flow** (replaced by authentication navigation)
- Kept for reference during development

### Data Model (`HouseCall.xcdatamodeld`)

#### Production Entities
- **User**: Encrypted user accounts
  - `id` (UUID), `email`, `encryptedPasswordHash`, `encryptedPasscodeHash`
  - `encryptedFullName`, `createdAt`, `lastLoginAt`
  - `authMethod` (password/passcode/biometric), `accountStatus`

- **Conversation**: Encrypted conversation storage
  - `id` (UUID), `userId` (UUID)
  - `encryptedTitle` (Binary Data) - encrypted conversation title
  - `createdAt` (Date), `updatedAt` (Date)
  - `isActive` (Boolean)
  - `llmProvider` (String) - "openai", "claude", "custom"
  - Relationship: `messages` (one-to-many with Message)

- **Message**: Encrypted message storage
  - `id` (UUID), `conversationId` (UUID)
  - `role` (String) - "user", "assistant", "system"
  - `encryptedContent` (Binary Data) - encrypted message text
  - `timestamp` (Date)
  - `tokenCount` (Int32)
  - `streamingComplete` (Boolean)
  - Relationship: `conversation` (many-to-one with Conversation)

- **AuditLogEntry**: HIPAA compliance audit trail
  - `id`, `timestamp`, `eventType`, `userId`
  - `encryptedDetails`, `deviceId`
  - Extended event types: conversation_created, conversation_accessed, conversation_deleted, message_created, ai_interaction, ai_interaction_failed, provider_switched, screenshot_detected

#### Legacy Entity (Deprecated)
- **Item**: Template entity from Xcode project
  - **Not used in production** (marked for future removal)

### Input Validation (`Utilities/Helpers/`)
- **Validators.swift**: Comprehensive input validation
  - Email: RFC 5322 format (NSDataDetector)
  - Password: 12+ chars, uppercase, lowercase, number, special char
  - Passcode: 6 digits, no sequential (123456), no repeated (111111)
  - Password strength assessment (0-5 scale)
  - Full name validation

### Testing Structure
- **HouseCallTests**: Unit tests using Swift Testing framework
  - `@Test` macro syntax with `#expect(...)` assertions
  - 265+ tests across 18 test files
  - 90%+ coverage for Core/Security, Core/Persistence, and Core/Services
  - In-memory Core Data for isolated testing

  **Authentication & Security Tests:**
  - EncryptionManagerTests.swift (20+ tests)
  - KeychainManagerTests.swift (20+ tests)
  - PasswordHasherTests.swift (25+ tests)
  - ValidatorsTests.swift (40+ tests)
  - UserRepositoryTests.swift (20+ tests)
  - AuditLoggerTests.swift (20+ tests)
  - BiometricAuthManagerTests.swift (10+ tests)
  - SecurityTests.swift (15+ tests for encryption, screen protection, session timeout)
  - APIKeySecurityTests.swift (25+ tests for API key storage and network security)

  **AI Chat System Tests:**
  - ConversationRepositoryTests.swift (18 tests for conversation CRUD with encryption)
  - MessageRepositoryTests.swift (20 tests for message persistence, pagination, streaming)
  - AIConversationServiceTests.swift (20+ tests for service orchestration)
  - OpenAIProviderTests.swift (33 tests for OpenAI provider)
  - ClaudeProviderTests.swift (30 tests for Claude provider)
  - CustomProviderTests.swift (37 tests for custom/self-hosted provider)
  - SSEParserTests.swift (12+ tests for Server-Sent Events parsing)
  - LLMProviderConfigManagerTests.swift (15+ tests for provider configuration)
  - IntegrationTests.swift (10+ AI chat integration tests)

- **HouseCallUITests**: UI testing target for end-to-end tests
  - ChatInterfaceUITests.swift (30+ UI tests for chat interaction, navigation, accessibility)

## Security Best Practices

### HIPAA Compliance
✅ **Encryption at Rest**: AES-256-GCM with FileProtectionType.complete
  - User credentials and personal information encrypted
  - All conversation titles encrypted
  - All message content encrypted
  - User-specific encryption keys via HKDF key derivation
✅ **Encryption in Transit**: TLS 1.2+ for all LLM provider API calls
  - OpenAI: HTTPS enforced (https://api.openai.com)
  - Anthropic Claude: HTTPS enforced (https://api.anthropic.com)
  - Custom providers: URL validation for secure protocols
✅ **Access Controls**: Session timeout, biometric authentication, authentication-gated chat
✅ **Audit Trail**: All events logged per 45 CFR § 164.312(b)
  - All authentication events
  - All conversation operations (create, access, delete, provider switch)
  - All AI interactions (start, complete, fail)
  - Screenshot detection
  - No PHI in audit logs (event metadata only)
✅ **Screen Protection**: Screenshot detection and privacy overlay
  - Screenshot attempts logged to audit trail
  - Privacy screen displayed in app switcher
✅ **No PHI in Logs**: Error messages never expose sensitive data
  - API keys never logged
  - Message content never logged
  - Encrypted audit log details

### Authentication Methods
1. **Password**: 12+ characters, complexity requirements, PBKDF2 hashing
2. **Passcode**: 6 digits, pattern validation (no 123456, 111111)
3. **Biometric**: Face ID/Touch ID with no stored credentials

### Session Management
- 5-minute inactivity timeout
- Background/foreground validation
- Automatic logout on timeout
- Session tokens in keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)

### Encrypted Core Data Usage

**Creating a user with encrypted data:**
```swift
let repository = CoreDataUserRepository()
let user = try repository.createUser(
    email: "patient@example.com",
    password: "SecurePassword123!",
    passcode: nil,
    fullName: "John Doe",
    authMethod: .password
)
// Full name and password hash are automatically encrypted
```

**Authenticating a user:**
```swift
let authService = AuthenticationService.shared
let user = try await authService.login(
    email: "patient@example.com",
    credential: "SecurePassword123!",
    authMethod: .password,
    useBiometric: false
)
// Creates session, logs audit event
```

**Accessing decrypted user data:**
```swift
if let fullName = try? authService.getCurrentUserFullName() {
    print("Welcome, \(fullName)")
}
```

### Working with Encrypted Conversations and Messages

**Creating a conversation with encrypted title:**
```swift
let conversationRepo = CoreDataConversationRepository()
let conversation = try conversationRepo.createConversation(
    userId: currentUserId,
    provider: .openai,
    title: "Headache and fever symptoms"
)
// Title is automatically encrypted before storage
```

**Retrieving and decrypting conversations:**
```swift
let conversations = try conversationRepo.fetchConversations(userId: currentUserId)
for conversation in conversations {
    let decryptedTitle = try conversationRepo.decryptConversationTitle(conversation)
    print("Conversation: \(decryptedTitle)")
}
```

**Creating a message with encrypted content:**
```swift
let messageRepo = CoreDataMessageRepository()
let message = try messageRepo.createMessage(
    conversationId: conversationId,
    role: .user,
    content: "I've had a headache for 3 days",
    streamingComplete: true
)
// Content is automatically encrypted before storage
```

**Streaming message updates (for AI responses):**
```swift
// Initial creation
var message = try messageRepo.createMessage(
    conversationId: conversationId,
    role: .assistant,
    content: "Based on",
    streamingComplete: false
)

// Update as chunks arrive
try messageRepo.updateMessageContent(
    id: message.id,
    content: "Based on your symptoms",
    complete: false,
    tokenCount: nil
)

// Mark complete when done
try messageRepo.updateMessageContent(
    id: message.id,
    content: "Based on your symptoms, I recommend...",
    complete: true,
    tokenCount: 150
)
```

**Sending a message via AIConversationService:**
```swift
let aiService = AIConversationService.shared
try await aiService.sendMessage(
    conversationId: conversationId,
    content: "What are common cold symptoms?"
)
// Service handles:
// - Encrypting user message
// - Calling LLM provider
// - Streaming AI response
// - Encrypting AI message
// - Audit logging
```

**Switching LLM providers:**
```swift
try await aiService.switchProvider(
    conversationId: conversationId,
    to: .claude
)
// Conversation context is maintained
// System message added to conversation
```

### LLM Provider Configuration

**Storing API keys securely:**
```swift
let configManager = LLMProviderConfigManager.shared

// Set OpenAI API key (stored in Keychain)
try configManager.setAPIKey("sk-...", for: .openai)

// Set Claude API key
try configManager.setAPIKey("sk-ant-...", for: .claude)

// Configure custom provider
try configManager.setCustomProviderConfig(
    baseURL: "http://localhost:11434",
    apiKey: nil,  // Optional for local servers
    model: "llama3"
)
```

**Retrieving provider configuration:**
```swift
let config = configManager.getConfig(for: .openai)
print("Model: \(config.model)")
print("Temperature: \(config.temperature)")
print("Max tokens: \(config.maxTokens)")

// API key retrieved securely from Keychain
if let apiKey = try? configManager.getAPIKey(for: .openai) {
    // Use API key for requests (never log it)
}
```

## Development Notes

### Error Handling
✅ **All fatalError() calls have been replaced** with proper error handling:
- `Persistence.swift`: Errors logged to audit trail, app continues
- `ContentView.swift`: Errors displayed to user with rollback
- All components throw typed errors for better debugging

### Working with Encrypted Data
Always use `EncryptionManager.shared` for PHI:
```swift
// Encrypt
let encrypted = try EncryptionManager.shared.encryptString("PHI data", for: userId)

// Decrypt
let decrypted = try EncryptionManager.shared.decryptString(encrypted, for: userId)
```

Never store PHI in plaintext in:
- Core Data (use encrypted binary fields)
- UserDefaults
- Logs or error messages
- Network requests (use TLS)

### SwiftUI Previews
All views should use `PersistenceController.preview` for SwiftUI previews to avoid affecting production data.

### Core Data Context
The `managedObjectContext` is injected via SwiftUI environment and should be accessed with `@Environment(\.managedObjectContext)` in views that need database access.

## Troubleshooting Guide

### AI Chat Issues

#### "Unable to connect to AI service"
**Symptoms**: Chat messages fail to send, error banner appears
**Causes**:
- No network connectivity
- API endpoint unreachable
- Provider service downtime

**Solutions**:
1. Check network connection
2. Verify API endpoint is reachable (use curl or Postman)
3. Check provider status pages:
   - OpenAI: https://status.openai.com
   - Anthropic: https://status.anthropic.com
4. Try switching to alternative provider in settings

#### "API authentication failed. Check settings."
**Symptoms**: Authentication error on message send
**Causes**:
- Invalid or expired API key
- Missing API key in Keychain
- Incorrect API key format

**Solutions**:
1. Navigate to Settings > LLM Provider Settings
2. Verify API key is entered correctly
3. Test configuration with "Test Configuration" button
4. For OpenAI: Key should start with `sk-`
5. For Claude: Key should start with `sk-ant-`
6. Re-enter API key if needed

#### "Rate limit exceeded. Wait 60s."
**Symptoms**: API calls blocked with rate limit error
**Causes**:
- Too many requests in short time period
- Exceeded provider's rate limits
- Free tier limitations

**Solutions**:
1. Wait for the countdown timer to complete
2. Upgrade to paid tier for higher rate limits
3. Configure rate limit handling in provider settings
4. Switch to alternative provider temporarily

#### Streaming Response Interrupted
**Symptoms**: AI response stops mid-sentence, partial text displayed
**Causes**:
- Network connection lost during streaming
- Provider timeout (>30 seconds)
- App backgrounded during response

**Solutions**:
1. Tap "Retry" button to resend last message
2. Check network stability
3. Keep app in foreground during long responses
4. Partial response is saved - visible in chat history

#### "Unable to decrypt conversation/message"
**Symptoms**: Conversation or message shows decryption error
**Causes**:
- User's encryption key changed
- Core Data corruption
- Logged in as different user

**Solutions**:
1. Verify logged in as correct user
2. Logout and login again to refresh encryption keys
3. If issue persists, conversation may be corrupted
4. Delete conversation and start new one
5. Report issue if problem continues

### Provider Configuration Issues

#### Custom Provider Not Working
**Symptoms**: Custom/self-hosted provider fails to respond
**Causes**:
- Incorrect base URL
- Provider not running
- Incompatible API format

**Solutions**:
1. Verify custom server is running (e.g., `curl http://localhost:11434/v1/models`)
2. Check base URL includes full path (e.g., `http://localhost:11434/v1/chat/completions`)
3. Ensure provider follows OpenAI-compatible API format
4. Check provider logs for errors
5. Test with Ollama: `ollama serve` then use `http://localhost:11434`

#### API Key Not Persisting
**Symptoms**: API key is lost after app restart
**Causes**:
- Keychain access issues
- App reinstallation
- iOS Keychain bug

**Solutions**:
1. Re-enter API key in settings
2. Tap "Save Settings" after entering key
3. Restart app to verify persistence
4. Check iOS Settings > Face ID & Passcode > Data Protection is enabled
5. If issue persists, check device storage is not full

### Performance Issues

#### Chat UI Laggy During Streaming
**Symptoms**: Choppy scrolling, delayed text updates
**Causes**:
- Too many messages in conversation
- Device memory pressure
- Main thread blocking

**Solutions**:
1. Delete old conversations to reduce memory usage
2. Restart app to clear caches
3. Use pagination - load only recent messages
4. Reduce max_tokens in provider settings for shorter responses

#### App Crashes on Message Send
**Symptoms**: App crashes when sending message
**Causes**:
- Out of memory
- Core Data save failure
- Encryption error

**Solutions**:
1. Check device storage - free up space if needed
2. Check Console.app logs for crash reports
3. Delete unused conversations to free Core Data space
4. Restart app and try again
5. If crash persists, report with crash logs

### Build and Test Issues

#### Tests Failing After Pull
**Symptoms**: Tests pass on one machine, fail on another
**Causes**:
- In-memory Core Data initialization issues
- Keychain conflicts between tests
- Async timing issues

**Solutions**:
1. Clean build folder: `xcodebuild clean -scheme HouseCall`
2. Delete Derived Data: `rm -rf ~/Library/Developer/Xcode/DerivedData`
3. Run tests individually to isolate failures
4. Check test logs for specific error messages
5. Ensure iOS Simulator is iPhone 15 (as specified in tests)

#### Keychain Tests Failing
**Symptoms**: KeychainManager tests fail with error -25300 (item not found)
**Causes**:
- Keychain not cleared between tests
- Simulator keychain access restrictions

**Solutions**:
1. Reset iOS Simulator: Device > Erase All Content and Settings
2. Ensure tests use unique keys per test case
3. Add cleanup in test teardown to remove Keychain items
4. Run tests on physical device if simulator issues persist

### Encryption Issues

#### "Encryption key not found"
**Symptoms**: Error when trying to encrypt/decrypt data
**Causes**:
- Master encryption key missing from Keychain
- User logged out
- Keychain cleared

**Solutions**:
1. Logout and login again to regenerate encryption keys
2. For new users, ensure `EncryptionManager.setupMasterKey()` called on first login
3. Check Keychain access permissions in iOS Settings
4. Verify app's Keychain entitlement is configured correctly

### Audit Logging

#### Audit Logs Not Appearing
**Symptoms**: Events not logged to audit trail
**Causes**:
- AuditLogger not initialized
- Core Data save failure
- Logging disabled in tests

**Solutions**:
1. Verify `AuditLogger.shared` is used (singleton pattern)
2. Check Core Data persistence is working
3. Query audit logs: `let logs = try auditRepo.fetchLogs(userId: userId)`
4. Ensure audit logging is enabled (not disabled for tests)

### Common Development Mistakes

#### ❌ Don't: Store API keys in code
```swift
// WRONG - API key exposed in code
let apiKey = "sk-1234567890abcdef"
```

#### ✅ Do: Store API keys in Keychain
```swift
// CORRECT - API key stored securely
try configManager.setAPIKey(userProvidedKey, for: .openai)
```

#### ❌ Don't: Log PHI data
```swift
// WRONG - Message content logged
print("User message: \(messageContent)")
```

#### ✅ Do: Log metadata only
```swift
// CORRECT - No PHI in logs
AuditLogger.log(eventType: .messageCreated, userId: userId, details: ["messageId": messageId])
```

#### ❌ Don't: Use fatalError for recoverable errors
```swift
// WRONG - App crashes on error
guard let user = currentUser else { fatalError("No user") }
```

#### ✅ Do: Use proper error handling
```swift
// CORRECT - Graceful error handling
guard let user = currentUser else {
    throw AuthenticationError.notAuthenticated
}
```

### Getting Help

For issues not covered in this guide:
1. Check GitHub Issues: https://github.com/markolonius/HouseCall/issues
2. Review OpenSpec documentation: `/openspec/changes/add-ai-chat-interface/`
3. Check test files for usage examples
4. Review audit logs for error details
5. Enable debug logging in provider implementations

## Automated Phase Workflow

Implementation is driven by an OpenSpec → beads → worktree → coder/tester/reviewer
→ PR loop. See [`docs/WORKFLOW.md`](docs/WORKFLOW.md) for the full description.

- To implement a phase of an approved OpenSpec change, run the single command
  `/run-phase <change-id> <phase>` (e.g. `/run-phase add-cloud-platform-mvp 3`).
  The main session acts as the orchestrator and dispatches the
  `coder`/`tester`/`reviewer` subagents itself.
- **Do not invoke the `coder`, `tester`, or `reviewer` subagents directly**, and
  do not implement phase tasks by hand — go through `/run-phase` so beads, the
  GitHub mirror, the worktree, and the per-phase PR stay consistent.
- The orchestrator may push its phase branch and open one PR, but never pushes
  to `main` and never force-pushes.
- One-time machine setup is `scripts/dev-bootstrap.sh` (macOS/Homebrew).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
