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

HouseCall is a HIPAA-compliant SwiftUI iOS healthcare application using Core Data for encrypted persistence. The app provides secure user authentication with biometric support (Face ID/Touch ID), encrypted data storage, comprehensive audit logging, session management for healthcare data protection, and a chat interface for patient interaction with the HouseCall health assistant. The iOS app is a cloud client: it never calls a model. All AI runs server-side in the Go agent runtime behind physician review.

## Build and Test Commands

Prefer `scripts/test.sh` (the phase gate): it builds, vets and tests whichever of the Go backend and iOS app changed. It uses the `iPhone 17,OS=latest` simulator (override with `HOUSECALL_SIMULATOR`).

### Building the App
```bash
# Build for iOS Simulator (Debug)
xcodebuild -scheme HouseCall -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build

# Build for iOS Simulator (Release)
xcodebuild -scheme HouseCall -configuration Release -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest' build

# Build and run (use Xcode or iOS Simulator)
open HouseCall.xcodeproj  # Then Cmd+R in Xcode
```

The app needs `CORE_API_BASE_URL` and `CORE_API_TENANT_ID` in `HouseCall/Config/Secrets.xcconfig` (copy from `Secrets.example.xcconfig`).

### Running Tests
```bash
# Run all tests
xcodebuild test -scheme HouseCall -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# Run unit tests only (HouseCallTests target)
xcodebuild test -scheme HouseCall -only-testing:HouseCallTests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'

# Run UI tests only (HouseCallUITests target)
xcodebuild test -scheme HouseCall -only-testing:HouseCallUITests -destination 'platform=iOS Simulator,name=iPhone 17,OS=latest'
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
  - Graceful fallback to password

- **AuditLogger.swift**: HIPAA-compliant audit trail (45 CFR § 164.312(b))
  - All authentication events logged
  - Encrypted event details
  - Millisecond-precision timestamps
  - Device ID tracking

#### Data Access Layer (`Core/Persistence/`)
- **UserRepository.swift**: User data access protocol
  - Supports two authentication methods: password, biometric
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
  - Email + password login against the Core API; biometric unlock of an existing session
  - Session management with 5-minute timeout
  - App lifecycle monitoring (background/foreground)
  - ObservableObject for SwiftUI integration

### AI Chat System

#### Conversation Data Layer (`Core/Persistence/`)
- **ConversationRepository.swift**: Conversation data access protocol
  - Create/read/update/delete conversations
  - User-specific conversation queries
  - Title encryption/decryption
  - Automatic audit logging

- **CoreDataConversationRepository.swift**: Core Data implementation
  - Encrypted conversation title storage
  - User ID-based conversation filtering
  - Conversation timestamp management
  - Integration with EncryptionManager

- **MessageRepository.swift**: Message data access protocol
  - Create/read/update/delete messages
  - Pagination support (limit/offset)
  - Message content updates
  - Content encryption/decryption
  - User ID retrieval for encryption

- **CoreDataMessageRepository.swift**: Core Data implementation
  - Encrypted message content storage
  - Message update support
  - Efficient pagination queries
  - Conversation relationship management

#### Cloud Client (`Core/Services/`, `Core/Services/Sync/`)
The app never calls a model. All AI runs server-side in the Go agent runtime behind physician review. The app requires the Core API (`CORE_API_BASE_URL`, `CORE_API_TENANT_ID` in `Secrets.xcconfig`); an unconfigured build shows a configuration error and there are no local-only accounts.
- **AIConversationService.swift**: Conversation orchestration
  - Create conversations, save encrypted user messages, hand off to sync
  - Assistant messages arrive whole (no streaming) and are stored encrypted
  - Audit logging integration
- **CoreAPIAuthClient.swift / CoreAPIConfig.swift**: Core API sign-in and build configuration
- **CloudSyncCoordinator.swift / SyncClient.swift**: Syncs conversations and messages with the Core API; resumes without restart after re-sign-in
- Without a valid token (expired/rejected, or after an offline sign-in) chat is read-only until the patient signs in again

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
  - Email + password against the Core API
  - Biometric unlock of a previously authenticated session
  - Offline fallback for a previously signed-in patient

#### Conversation Views (`Features/Conversation/Views/`)
- **ConversationListView.swift**: Conversation list with navigation
  - Displays all user conversations (sorted by updatedAt)
  - Encrypted conversation titles (decrypted for display)
  - "New Chat" button in toolbar and empty state
  - Swipe-to-delete gesture
  - Navigation to ChatView on tap
  - Embedded ConversationListViewModel

- **ChatView.swift**: Chat interface
  - Scrollable message list with ScrollViewReader
  - Message bubbles (user: right-aligned blue, assistant: left-aligned gray)
  - "Waiting for a reply" indicator while the agent answers
  - Message input with Send/Clear buttons
  - Read-only mode: "Sign in to send messages" banner with an in-place password sheet
  - Error banner with retry functionality

- **MessageBubbleView.swift**: Message display component
  - User messages: right-aligned, blue background
  - AI messages: left-aligned, gray background
  - System messages: centered, italic
  - Multi-line text support
  - Timestamp display on tap
  - VoiceOver accessibility labels

#### ViewModels
**Authentication** (`Features/Authentication/ViewModels/`)
- **SignUpViewModel**: Registration logic with real-time validation
- **LoginViewModel**: Login orchestration with biometric support

**Conversation** (`Features/Conversation/ViewModels/`)
- **ConversationViewModel**: Chat view state management
  - Load conversations and messages
  - Send messages; "waiting for a reply" state while the agent answers
  - Read-only state and in-place sign-in when there is no valid token
  - Error handling and retry logic
  - ObservableObject for SwiftUI integration

#### Deprecated (`ContentView.swift`)
- Template view from Xcode project creation
- **Not used in app flow** (replaced by authentication navigation)
- Kept for reference during development

### Data Model (`HouseCall.xcdatamodeld`)

#### Production Entities
- **User**: Encrypted user accounts
  - `id` (UUID), `email`, `encryptedPasswordHash`
  - `encryptedFullName`, `createdAt`, `lastLoginAt`
  - `authMethod` (password/biometric), `accountStatus`

- **Conversation**: Encrypted conversation storage
  - `id` (UUID), `userId` (UUID)
  - `encryptedTitle` (Binary Data) - encrypted conversation title
  - `createdAt` (Date), `updatedAt` (Date)
  - `isActive` (Boolean)
  - `llmProvider` (String) - legacy, unused; kept to avoid a Core Data migration
  - Relationship: `messages` (one-to-many with Message)

- **Message**: Encrypted message storage
  - `id` (UUID), `conversationId` (UUID)
  - `role` (String) - "user", "assistant", "system"
  - `encryptedContent` (Binary Data) - encrypted message text
  - `timestamp` (Date)
  - `tokenCount` (Int32)
  - `streamingComplete` (Boolean) - legacy; assistant messages arrive whole
  - Relationship: `conversation` (many-to-one with Conversation)

- **AuditLogEntry**: HIPAA compliance audit trail
  - `id`, `timestamp`, `eventType`, `userId`
  - `encryptedDetails`, `deviceId`
  - Extended event types: conversation_created, conversation_accessed, conversation_deleted, message_created, screenshot_detected

#### Legacy Entity (Deprecated)
- **Item**: Template entity from Xcode project
  - **Not used in production** (marked for future removal)

### Input Validation (`Utilities/Helpers/`)
- **Validators.swift**: Comprehensive input validation
  - Email: RFC 5322 format (NSDataDetector)
  - Password: 12+ chars, uppercase, lowercase, number, special char
  - Password strength assessment (0-5 scale)
  - Full name validation

### Testing Structure
- **HouseCallTests**: Unit tests using Swift Testing framework
  - `@Test` macro syntax with `#expect(...)` assertions
  - Run through `scripts/test.sh` (builds, vets, tests what changed)
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

  **Chat and Cloud Client Tests:**
  - ConversationRepositoryTests.swift, MessageRepositoryTests.swift (encrypted persistence, pagination)
  - AIConversationServiceTests.swift, ConversationViewModelTests.swift, ReadOnlyChatTests.swift, ProviderlessConversationTests.swift
  - Cloud*Tests.swift, CoreAPIAuthClientTests.swift, SyncClientTests.swift (Core API sign-in, offline fallback, sync)
  - IntegrationTests.swift

- **HouseCallUITests**: UI testing target for end-to-end tests
  - ChatInterfaceUITests.swift (30+ UI tests for chat interaction, navigation, accessibility)

## Security Best Practices

### HIPAA Compliance
✅ **Encryption at Rest**: AES-256-GCM with FileProtectionType.complete
  - User credentials and personal information encrypted
  - All conversation titles encrypted
  - All message content encrypted
  - User-specific encryption keys via HKDF key derivation
✅ **Encryption in Transit**: TLS 1.2+ for all Core API calls (the app talks only to the Core API, never to a model vendor)
✅ **Access Controls**: Session timeout, biometric authentication, authentication-gated chat
✅ **Audit Trail**: All events logged per 45 CFR § 164.312(b)
  - All authentication events
  - All conversation operations (create, access, delete)
  - Sign-in and sync events
  - Screenshot detection
  - No PHI in audit logs (event metadata only)
✅ **Screen Protection**: Screenshot detection and privacy overlay
  - Screenshot attempts logged to audit trail
  - Privacy screen displayed in app switcher
✅ **No PHI in Logs**: Error messages never expose sensitive data
  - No model API keys exist on the device
  - Message content never logged
  - Encrypted audit log details

### Authentication Methods
1. **Password**: 12+ characters, complexity requirements; verified by the Core API (a local PBKDF2 hash supports the offline fallback)
2. **Biometric**: Face ID/Touch ID unlocks a previously authenticated session; no stored credentials

The 6-digit passcode method has been removed.

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
    fullName: "John Doe",
    authMethod: .password,
    id: patientId  // Core API patientId keeps the encryption identity stable
)
// Full name and password hash are automatically encrypted
```

**Signing in:**
Sign-in is email + password against the Core API (`CoreAPIAuthClient`); there are no local-only accounts. Face ID / Touch ID only unlocks a previously authenticated session. If the server is unreachable, a previously signed-in patient can still open their encrypted local history, read-only until a token is available.

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
    content: "I've had a headache for 3 days"
)
// Content is automatically encrypted before storage
```

**Sending a message:**
`AIConversationService` saves the encrypted user message locally and `CloudSyncCoordinator` syncs it to the Core API. The assistant reply is produced server-side by the agent runtime, synced down whole, and stored encrypted. The app never calls a model and holds no model API keys.

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

#### Chat is read-only ("Sign in to send messages")
**Symptoms**: History is visible but sending is disabled and a banner asks the user to sign in
**Causes**:
- Core API token expired or was rejected
- Signed in through the offline fallback (server was unreachable)

**Solutions**:
1. Tap the banner and enter the account password in the in-place sheet; sync resumes without restarting
2. If it fails, check the network and that the Core API is reachable

#### Reply never arrives
**Symptoms**: The "waiting for a reply" indicator stays up
**Causes**:
- The server-side agent is still working, or the Core API is unreachable
- The reply is held for physician review

**Solutions**:
1. Check network connectivity and Core API health
2. Assistant messages arrive whole (no streaming) through sync
3. Check the Go backend logs for the agent run

#### Configuration error at launch
**Symptoms**: App shows a Core API configuration error
**Causes**:
- `CORE_API_BASE_URL` / `CORE_API_TENANT_ID` missing from `Secrets.xcconfig`

**Solutions**:
1. Copy `HouseCall/Config/Secrets.example.xcconfig` to `Secrets.xcconfig` and fill in both values
2. Rebuild

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

### Performance Issues

#### Chat UI Laggy With Long Histories
**Symptoms**: Choppy scrolling in a long conversation
**Causes**:
- Too many messages in conversation
- Device memory pressure
- Main thread blocking

**Solutions**:
1. Delete old conversations to reduce memory usage
2. Restart app to clear caches
3. Use pagination - load only recent messages

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
5. Run through `scripts/test.sh` (iPhone 17 simulator, `OS=latest`)
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
5. Run `scripts/test.sh` to build, vet and test what your change touched

## Automated Phase Workflow

Implementation is driven by an OpenSpec → beads → worktree → coder → test
script + reviewer → PR loop. See [`docs/WORKFLOW.md`](docs/WORKFLOW.md).

- To implement a phase of an approved OpenSpec change, run
  `/run-phase <change-id> <phase>`. The main session is the orchestrator: it
  dispatches the `coder` subagent per task, then gates the phase once with
  `scripts/test.sh` and one `reviewer` pass over the whole phase diff.
- **Do not invoke the `coder` or `reviewer` subagents directly** for phase
  work, and do not implement phase tasks by hand — go through `/run-phase` so
  beads, the worktree, and the per-phase PR stay consistent.
- Each phase PR targets `main` and must be merged before the next phase starts.
  The orchestrator never pushes to `main` and never force-pushes.
- Small standalone fixes do not need the pipeline: a plain branch and PR.
- Run tests with `scripts/test.sh` (`--all` for both suites).
- One-time machine setup is `scripts/dev-bootstrap.sh` (macOS/Homebrew).


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
