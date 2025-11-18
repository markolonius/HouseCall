# Implementation Tasks: HIPAA-Compliant Account Creation

## 1. Core Data Model and Encryption Infrastructure

### 1.1 Update Core Data Model
- [ ] 1.1.1 Open `HouseCall.xcdatamodeld` in Xcode Data Model Editor
- [ ] 1.1.2 Add `User` entity with attributes:
  - `id` (UUID, required, indexed)
  - `email` (String, required, indexed) - NO unique constraint in MVP (single user per device)
  - `encryptedPasswordHash` (Binary Data, optional) - nil if using passcode-only
  - `encryptedPasscodeHash` (Binary Data, optional) - nil if using password-only
  - `encryptedFullName` (Binary Data, required)
  - `createdAt` (Date, required)
  - `lastLoginAt` (Date, optional)
  - `authMethod` (String, required) - "biometric", "password", or "passcode"
  - `accountStatus` (String, default "active") - for security_locked state
- [ ] 1.1.3 Add `AuditLogEntry` entity with attributes:
  - `id` (UUID, required, indexed)
  - `timestamp` (Date, required, indexed)
  - `eventType` (String, required, indexed)
  - `userId` (UUID, optional, indexed)
  - `encryptedDetails` (Binary Data, required)
  - `deviceId` (String, required)
- [ ] 1.1.4 Generate NSManagedObject subclasses for User and AuditLogEntry
- [ ] 1.1.5 Validate Core Data model compiles without errors
- [ ] 1.1.6 Add TODO comment: "Future PR: Add email unique constraint when multi-user support is needed"

### 1.2 Create Encryption Manager
- [ ] 1.2.1 Create `Core/Security/EncryptionManager.swift`
- [ ] 1.2.2 Implement master key generation using `SymmetricKey.init(size: .bits256)`
- [ ] 1.2.3 Implement keychain storage/retrieval for master key with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- [ ] 1.2.4 Implement HKDF-based user-specific key derivation using user UUID as salt
- [ ] 1.2.5 Implement AES-256-GCM encryption method: `encrypt(data: Data, for userId: UUID) throws -> EncryptedData`
- [ ] 1.2.6 Implement AES-256-GCM decryption method: `decrypt(encryptedData: EncryptedData, for userId: UUID) throws -> Data`
- [ ] 1.2.7 Add `EncryptedData` struct to bundle ciphertext + nonce
- [ ] 1.2.8 Implement derived key caching in memory with session-based lifecycle
- [ ] 1.2.9 Add error handling for CryptoKit operations (never use fatalError)
- [ ] 1.2.10 Write unit tests for encryption/decryption with test vectors

### 1.3 Create Keychain Manager
- [ ] 1.3.1 Create `Core/Security/KeychainManager.swift`
- [ ] 1.3.2 Implement generic keychain save: `save(data: Data, for key: String, accessibility: CFString) throws`
- [ ] 1.3.3 Implement generic keychain retrieve: `retrieve(for key: String) throws -> Data?`
- [ ] 1.3.4 Implement generic keychain delete: `delete(for key: String) throws`
- [ ] 1.3.5 Add support for storing SymmetricKey objects (master encryption key)
- [ ] 1.3.6 Add support for storing session tokens (UUIDs)
- [ ] 1.3.7 Add support for storing biometric enrollment flags (Bool)
- [ ] 1.3.8 Implement error mapping from Security framework errors to user-friendly messages
- [ ] 1.3.9 Write unit tests for keychain operations (use test keychain, not production)

### 1.4 Add Bcrypt Dependency
- [ ] 1.4.1 Open `HouseCall.xcodeproj` in Xcode
- [ ] 1.4.2 Add Swift Package Manager dependency for bcrypt (e.g., `https://github.com/vapor/bcrypt.git`)
- [ ] 1.4.3 Add `import Bcrypt` to relevant files
- [ ] 1.4.4 Verify package resolves and builds successfully

### 1.5 Create Password Hashing Service
- [ ] 1.5.1 Create `Core/Security/PasswordHasher.swift`
- [ ] 1.5.2 Implement bcrypt hashing: `hash(password: String) throws -> String` with cost factor 12
- [ ] 1.5.3 Implement bcrypt verification: `verify(password: String, hash: String) throws -> Bool`
- [ ] 1.5.4 Add secure memory cleanup (zero out password strings after use)
- [ ] 1.5.5 Write unit tests for password hashing and verification

### 1.6 Enhance Persistence Controller with Encryption
- [ ] 1.6.1 Update `Persistence.swift` to set `NSFileProtectionComplete` on persistent store
- [ ] 1.6.2 Add configuration: `storeDescription.setOption(FileProtectionType.complete as NSObject, forKey: NSPersistentStoreFileProtectionKey)`
- [ ] 1.6.3 Replace all `fatalError()` calls with proper error handling (throw/return errors)
- [ ] 1.6.4 Add error logging to audit log for Core Data failures
- [ ] 1.6.5 Test Core Data initialization with file protection enabled

## 2. Biometric Authentication

### 2.1 Create Biometric Authentication Manager
- [ ] 2.1.1 Create `Core/Security/BiometricAuthManager.swift`
- [ ] 2.1.2 Import `LocalAuthentication` framework
- [ ] 2.1.3 Implement biometric availability check: `isBiometricAvailable() -> BiometricType` (FaceID/TouchID/None)
- [ ] 2.1.4 Implement biometric authentication: `authenticate(reason: String, completion: (Result<Bool, Error>) -> Void)`
- [ ] 2.1.5 Add user-friendly reason strings appropriate for healthcare context
- [ ] 2.1.6 Handle `LAError` cases (user cancel, fallback, lockout, etc.)
- [ ] 2.1.7 Write unit tests with mocked LAContext

### 2.2 Add Privacy Permissions
- [ ] 2.2.1 Open `Info.plist`
- [ ] 2.2.2 Add `NSFaceIDUsageDescription` key with value: "HouseCall uses Face ID to securely protect your health information and verify your identity."
- [ ] 2.2.3 Verify privacy description displays correctly when biometric permission requested

## 3. Audit Logging

### 3.1 Create Audit Logger
- [ ] 3.1.1 Create `Core/Security/AuditLogger.swift`
- [ ] 3.1.2 Define `AuditEventType` enum with cases: account_created, login_success, login_failure, biometric_enrolled, session_timeout, security_alert_tampering, etc.
- [ ] 3.1.3 Implement `log(event:userId:details:)` method to create AuditLogEntry
- [ ] 3.1.4 Encrypt event details JSON before storing in Core Data
- [ ] 3.1.5 Generate unique device identifier (UUID stored in UserDefaults)
- [ ] 3.1.6 Add timestamp with millisecond precision
- [ ] 3.1.7 Write unit tests for audit logging

### 3.2 Create Audit Log Query Interface
- [ ] 3.2.1 Add query methods: `fetchEvents(for userId: UUID, eventType: AuditEventType?, dateRange: ClosedRange<Date>?) -> [AuditLogEntry]`
- [ ] 3.2.2 Implement decryption of event details for authorized review
- [ ] 3.2.3 Add sorting by timestamp (chronological order)
- [ ] 3.2.4 Write unit tests for audit queries

## 4. User Repository and Data Access Layer

### 4.1 Define User Repository Protocol
- [ ] 4.1.1 Create `Core/Persistence/UserRepository.swift` protocol
- [ ] 4.1.2 Define methods:
  - `createUser(email:password:passcode:fullName:authMethod:) throws -> User`
  - `findUser(by email: String) -> User?`
  - `findUser(by id: UUID) -> User?`
  - `updateUser(_ user: User) throws`
  - `authenticateUser(email:credential:authMethod:) throws -> User` (credential is password or passcode)
  - `isEmailRegistered(_ email: String) -> Bool` (for future use, not enforced in MVP)
- [ ] 4.1.3 Define custom errors: `UserRepositoryError` (invalidCredentials, encryptionFailed, invalidAuthMethod, etc.)
- [ ] 4.1.4 Add TODO: "Future PR: Add duplicateEmail error when uniqueness constraint is implemented"

### 4.2 Implement Core Data User Repository
- [ ] 4.2.1 Create `Core/Persistence/CoreDataUserRepository.swift`
- [ ] 4.2.2 Inject `EncryptionManager`, `PasswordHasher`, and `NSManagedObjectContext` as dependencies
- [ ] 4.2.3 Implement `createUser`:
  - Hash password OR passcode (based on authMethod)
  - Encrypt fields (passwordHash/passcodeHash, fullName)
  - Save to Core Data with authMethod stored
  - Log audit event
- [ ] 4.2.4 Implement `findUser` methods with Core Data fetch requests
- [ ] 4.2.5 Implement `authenticateUser`:
  - Fetch user by email
  - Check authMethod to determine which credential to verify
  - Decrypt appropriate hash (password or passcode)
  - Verify with bcrypt
  - Log audit event (success/failure)
- [ ] 4.2.6 Implement `isEmailRegistered`: simple fetch by email (no uniqueness enforcement in MVP)
- [ ] 4.2.7 Add error handling and rollback for failed transactions
- [ ] 4.2.8 Write unit tests with in-memory Core Data stack (test all auth methods)

## 5. Authentication Service and Session Management

### 5.1 Create Authentication Service
- [ ] 5.1.1 Create `Core/Services/AuthenticationService.swift`
- [ ] 5.1.2 Inject `UserRepository`, `KeychainManager`, `BiometricAuthManager`, and `AuditLogger`
- [ ] 5.1.3 Implement `register(email:password:passcode:fullName:authMethod:) async throws -> User`
- [ ] 5.1.4 Implement `login(email:credential:authMethod:biometric:) async throws -> User`
- [ ] 5.1.5 Implement `logout() async throws`
- [ ] 5.1.6 Implement `createSession(for user: User) throws -> UUID` (session token)
- [ ] 5.1.7 Implement `validateSession() -> User?` (check keychain for valid session)
- [ ] 5.1.8 Implement `invalidateSession() throws`
- [ ] 5.1.9 Add session timeout tracking (5-minute inactivity timer)
- [ ] 5.1.10 Store user's preferred authMethod in keychain for login screen pre-population
- [ ] 5.1.11 Write unit tests for authentication flows (password, passcode, biometric)

### 5.2 Add Session Timeout Handling
- [ ] 5.2.1 Create session timeout timer using `Combine` or `Timer`
- [ ] 5.2.2 Reset timer on user interaction (tap, swipe, keyboard input)
- [ ] 5.2.3 Invalidate session and navigate to login after 5 minutes inactivity
- [ ] 5.2.4 Handle app backgrounding: start background timer, require re-auth if timeout exceeded
- [ ] 5.2.5 Log session timeout events in audit log

## 6. Input Validation

### 6.1 Create Validation Utilities
- [ ] 6.1.1 Create `Utilities/Helpers/Validators.swift`
- [ ] 6.1.2 Implement email validation using RFC 5322 regex or `NSDataDetector`
- [ ] 6.1.3 Implement password strength validation:
  - Minimum 12 characters
  - At least one uppercase letter
  - At least one lowercase letter
  - At least one number
  - At least one special character (!@#$%^&*()_+-=[]{}|;:,.<>?)
- [ ] 6.1.4 Implement password confirmation matching
- [ ] 6.1.5 Implement 6-digit passcode validation:
  - Exactly 6 numeric digits
  - Reject sequential patterns (123456, 654321, etc.)
  - Reject repeated digits (111111, 000000, etc.)
  - Return specific error messages for invalid patterns
- [ ] 6.1.6 Implement passcode confirmation matching
- [ ] 6.1.7 Return validation result with specific error messages
- [ ] 6.1.8 Write unit tests for all validation rules (password + passcode)

## 7. SwiftUI Views and ViewModels

### 7.1 Create Authentication ViewModels
- [ ] 7.1.1 Create `Features/Authentication/ViewModels/SignUpViewModel.swift`
- [ ] 7.1.2 Add `@Published` properties: email, password, confirmPassword, fullName, errorMessage, isLoading, authMethod (password/passcode)
- [ ] 7.1.3 Inject `AuthenticationService` dependency
- [ ] 7.1.4 Implement `signUp()` method with async/await (handles both password and passcode paths)
- [ ] 7.1.5 Add real-time validation for email, password, and passcode (as user types)
- [ ] 7.1.6 Handle errors and map to user-friendly messages
- [ ] 7.1.7 Navigate to authentication method selection or biometric setup on success
- [ ] 7.1.8 Write unit tests for ViewModel logic (password + passcode paths)

- [ ] 7.1.9 Create `Features/Authentication/ViewModels/LoginViewModel.swift`
- [ ] 7.1.10 Add `@Published` properties: email, password, passcode, errorMessage, isLoading, authMethod (detected from user account)
- [ ] 7.1.11 Implement `login()` method with biometric/password/passcode flow
- [ ] 7.1.12 Navigate to AI chat on success
- [ ] 7.1.13 Write unit tests for LoginViewModel (all auth methods)

- [ ] 7.1.14 Create `Features/Authentication/ViewModels/AuthMethodSelectionViewModel.swift`
- [ ] 7.1.15 Add `@Published` properties: selectedMethod (biometric/password/passcode), deviceSupportsbiometric
- [ ] 7.1.16 Inject `BiometricAuthManager`
- [ ] 7.1.17 Implement method selection logic and navigation
- [ ] 7.1.18 Write unit tests for AuthMethodSelectionViewModel

- [ ] 7.1.19 Create `Features/Authentication/ViewModels/BiometricSetupViewModel.swift`
- [ ] 7.1.20 Inject `BiometricAuthManager` and `AuthenticationService`
- [ ] 7.1.21 Implement `enrollBiometric()` and `usePasscode()` methods
- [ ] 7.1.22 Navigate to passcode setup or AI chat interface after decision
- [ ] 7.1.23 Write unit tests for BiometricSetupViewModel

### 7.2 Create Sign Up View
- [ ] 7.2.1 Create `Features/Authentication/Views/SignUpView.swift`
- [ ] 7.2.2 Add `@StateObject` for `SignUpViewModel`
- [ ] 7.2.3 Create form with fields: email, password, confirm password, full name
- [ ] 7.2.4 Add real-time validation indicators (green checkmark for valid fields)
- [ ] 7.2.5 Display password strength requirements with visual feedback
- [ ] 7.2.6 Add "Create Account" button with loading state
- [ ] 7.2.7 Display error messages with appropriate styling
- [ ] 7.2.8 Add accessibility labels and hints for VoiceOver
- [ ] 7.2.9 Support Dynamic Type for text scaling
- [ ] 7.2.10 Add link to "Already have an account? Log in"
- [ ] 7.2.11 Test with VoiceOver and high contrast mode

### 7.3 Create Login View
- [ ] 7.3.1 Create `Features/Authentication/Views/LoginView.swift`
- [ ] 7.3.2 Add `@StateObject` for `LoginViewModel`
- [ ] 7.3.3 Create form with fields: email, password
- [ ] 7.3.4 Add "Log In" button with biometric icon if enabled
- [ ] 7.3.5 Display error messages
- [ ] 7.3.6 Add accessibility support
- [ ] 7.3.7 Add link to "Don't have an account? Sign up"
- [ ] 7.3.8 Test login flow with biometric and password-only accounts

### 7.4 Create Authentication Method Selection View
- [ ] 7.4.1 Create `Features/Authentication/Views/AuthMethodSelectionView.swift`
- [ ] 7.4.2 Add `@StateObject` for `AuthMethodSelectionViewModel`
- [ ] 7.4.3 Display three authentication options:
  - Face ID/Touch ID (if available)
  - Password (12+ characters)
  - 6-Digit Passcode
- [ ] 7.4.4 Show healthcare-appropriate explanation for each method
- [ ] 7.4.5 Highlight recommended method based on device capabilities
- [ ] 7.4.6 Add "Continue" button to proceed with selected method
- [ ] 7.4.7 Add accessibility support
- [ ] 7.4.8 Test on devices with/without biometric hardware

### 7.5 Create Biometric Setup View
- [ ] 7.5.1 Create `Features/Authentication/Views/BiometricSetupView.swift`
- [ ] 7.5.2 Add `@StateObject` for `BiometricSetupViewModel`
- [ ] 7.5.3 Display explanation of biometric security benefits (healthcare-appropriate messaging)
- [ ] 7.5.4 Show Face ID or Touch ID icon based on device capability
- [ ] 7.5.5 Add "Enable Biometric Authentication" button
- [ ] 7.5.6 Add "Use 6-Digit Passcode Instead" button as alternative
- [ ] 7.5.7 Handle biometric unavailable state gracefully (auto-navigate to passcode)
- [ ] 7.5.8 Add accessibility support
- [ ] 7.5.9 Test on devices with/without biometric hardware

### 7.6 Create Passcode Setup View
- [ ] 7.6.1 Create `Features/Authentication/Views/PasscodeSetupView.swift`
- [ ] 7.6.2 Add `@StateObject` for `PasscodeSetupViewModel`
- [ ] 7.6.3 Display numeric keypad for 6-digit entry (use SecureField with numeric keyboard)
- [ ] 7.6.4 Show visual indicators for each entered digit (bullets/circles)
- [ ] 7.6.5 Implement real-time validation (reject sequential/repeated patterns)
- [ ] 7.6.6 Add passcode confirmation step (enter twice)
- [ ] 7.6.7 Display clear error messages for invalid patterns
- [ ] 7.6.8 Add "Back" option to return to biometric setup
- [ ] 7.6.9 Add accessibility support (VoiceOver announces each digit)
- [ ] 7.6.10 Navigate to AI chat interface on successful passcode creation

### 7.7 Create Root Navigation Logic
- [ ] 7.7.1 Update `HouseCallApp.swift` to check authentication state on launch
- [ ] 7.7.2 Inject `AuthenticationService` as `@StateObject` or environment object
- [ ] 7.7.3 Implement conditional navigation:
  - No account → SignUpView
  - Valid session → AI Chat Interface (ContentView placeholder for now)
  - Expired session → LoginView
- [ ] 7.7.4 Handle session timeout navigation during app use
- [ ] 7.7.5 Test navigation flows for all states (password, passcode, biometric)

## 8. Testing

### 8.1 Unit Tests
- [ ] 8.1.1 Test `EncryptionManager`: encryption/decryption, key derivation, error cases
- [ ] 8.1.2 Test `KeychainManager`: save/retrieve/delete, accessibility settings
- [ ] 8.1.3 Test `PasswordHasher`: bcrypt hashing, verification, security
- [ ] 8.1.4 Test `BiometricAuthManager`: availability checks, authentication flows (mocked)
- [ ] 8.1.5 Test `AuditLogger`: event creation, encryption, querying
- [ ] 8.1.6 Test `Validators`: email format, password strength, edge cases
- [ ] 8.1.7 Test `UserRepository`: CRUD operations, error handling, encryption integration
- [ ] 8.1.8 Test `AuthenticationService`: registration, login, session management
- [ ] 8.1.9 Test ViewModels: business logic, error handling, state management
- [ ] 8.1.10 Achieve 90%+ code coverage for Core/Security and Core/Services

### 8.2 UI Tests
- [ ] 8.2.1 Create `HouseCallUITests/AuthenticationUITests.swift`
- [ ] 8.2.2 Test complete sign-up flow with password: enter data, create account, biometric setup
- [ ] 8.2.3 Test complete sign-up flow with passcode: enter data, choose passcode, setup passcode
- [ ] 8.2.4 Test validation errors: invalid email, weak password, password mismatch, invalid passcode patterns
- [ ] 8.2.5 Test login flow with password: successful login, invalid credentials
- [ ] 8.2.6 Test login flow with passcode: successful login, invalid passcode
- [ ] 8.2.7 Test login flow with biometric: successful login, biometric failure with fallback
- [ ] 8.2.8 Test biometric enrollment flow (simulate success/decline to passcode)
- [ ] 8.2.9 Test passcode setup flow: entry, validation, confirmation, navigation
- [ ] 8.2.10 Test authentication method selection UI (biometric vs password vs passcode)
- [ ] 8.2.11 Test session persistence: close app, reopen within timeout, auto-login (all auth methods)
- [ ] 8.2.12 Test session timeout: wait 5 minutes (or use time manipulation), require re-login
- [ ] 8.2.13 Test logout flow
- [ ] 8.2.14 Test accessibility: VoiceOver navigation, Dynamic Type, high contrast (all screens)
- [ ] 8.2.15 Add TODO: "Future PR: Test duplicate email error when uniqueness is enforced"

### 8.3 Security Tests
- [ ] 8.3.1 Verify Core Data file is encrypted (check filesystem protection)
- [ ] 8.3.2 Verify keychain items have correct accessibility attributes
- [ ] 8.3.3 Verify passwords are never stored in plaintext (inspect Core Data, logs, memory dumps)
- [ ] 8.3.4 Verify audit log contains all required events
- [ ] 8.3.5 Test encryption key rotation (future: when implementing key rotation)
- [ ] 8.3.6 Test data tampering detection (modify encrypted Core Data, verify authentication tag failure)
- [ ] 8.3.7 Verify no PHI in logs or error messages
- [ ] 8.3.8 Test session timeout enforcement
- [ ] 8.3.9 Test keychain cleanup on logout

## 9. Documentation and Cleanup

### 9.1 Code Documentation
- [ ] 9.1.1 Add inline documentation comments to all public methods
- [ ] 9.1.2 Document security-critical code paths with rationale
- [ ] 9.1.3 Add code examples for common authentication flows

### 9.2 Update CLAUDE.md
- [ ] 9.2.1 Document new authentication architecture
- [ ] 9.2.2 Add guidance for working with encrypted Core Data
- [ ] 9.2.3 Document security best practices for contributors

### 9.3 Remove Template Code
- [ ] 9.3.1 Remove `Item` entity from Core Data model (or keep for reference, mark as deprecated)
- [ ] 9.3.2 Update `ContentView.swift` to placeholder for AI chat (or keep template for testing)
- [ ] 9.3.3 Clean up unused code and imports

## 10. Final Validation and Deployment Prep

### 10.1 Pre-Launch Checklist
- [ ] 10.1.1 Run all unit tests and verify 90%+ coverage for security components
- [ ] 10.1.2 Run all UI tests and verify critical flows pass
- [ ] 10.1.3 Perform manual testing on physical device (biometric hardware required)
- [ ] 10.1.4 Test on multiple iOS versions (iOS 15, 16, 17+)
- [ ] 10.1.5 Test accessibility with VoiceOver, Dynamic Type, high contrast
- [ ] 10.1.6 Review audit log completeness
- [ ] 10.1.7 Verify no `fatalError()` calls remain in production code paths
- [ ] 10.1.8 Perform security audit of encryption implementation
- [ ] 10.1.9 Review HIPAA compliance checklist for technical safeguards
- [ ] 10.1.10 Obtain approval to proceed with AI chat interface integration

### 10.2 Build and Archive
- [ ] 10.2.1 Build Release configuration and verify no warnings
- [ ] 10.2.2 Test Release build on device (Debug builds behave differently)
- [ ] 10.2.3 Archive build for TestFlight distribution (if applicable)
- [ ] 10.2.4 Document known limitations (no password reset, no multi-device sync)
