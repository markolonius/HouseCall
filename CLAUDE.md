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

HouseCall is a HIPAA-compliant SwiftUI iOS healthcare application using Core Data for encrypted persistence. The app provides secure user authentication with biometric support (Face ID/Touch ID), encrypted data storage, comprehensive audit logging, and session management for healthcare data protection.

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

### UI Layer

#### App Navigation (`HouseCallApp.swift`)
- Conditional navigation based on authentication state:
  - `isAuthenticated == false` → LoginView
  - `isAuthenticated == true` → MainAppView
- Session validation on app launch
- AuthenticationService as environment object

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

- **MainAppView.swift**: Post-authentication welcome screen
  - Decrypted user information display
  - Logout functionality
  - Placeholder for AI chat interface

#### ViewModels (`Features/Authentication/ViewModels/`)
- **SignUpViewModel**: Registration logic with real-time validation
- **LoginViewModel**: Login orchestration with biometric support

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

- **AuditLogEntry**: HIPAA compliance audit trail
  - `id`, `timestamp`, `eventType`, `userId`
  - `encryptedDetails`, `deviceId`

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
  - 125+ tests across 8 test files
  - 90%+ coverage for Core/Security and Core/Persistence
  - In-memory Core Data for isolated testing

  Test files:
  - EncryptionManagerTests.swift (20+ tests)
  - KeychainManagerTests.swift (20+ tests)
  - PasswordHasherTests.swift (25+ tests)
  - ValidatorsTests.swift (40+ tests)
  - UserRepositoryTests.swift (20+ tests)
  - AuditLoggerTests.swift (20+ tests)
  - BiometricAuthManagerTests.swift (10+ tests)

- **HouseCallUITests**: UI testing target for end-to-end tests

## Security Best Practices

### HIPAA Compliance
✅ **Encryption at Rest**: AES-256-GCM with FileProtectionType.complete
✅ **Encryption in Transit**: TLS for network communications (when added)
✅ **Access Controls**: Session timeout, biometric authentication
✅ **Audit Trail**: All events logged per 45 CFR § 164.312(b)
✅ **No PHI in Logs**: Error messages never expose sensitive data

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
