# Authentication Capability Specification

## Purpose
Define how the app authenticates users (registration, login, passcode, biometric), manages sessions, and keeps SwiftUI authentication-state updates thread-safe and free of publishing violations.
## Requirements
### Requirement: Session Creation State Management
The authentication service SHALL manage session state updates by deferring @Published property changes to prevent SwiftUI publishing violations during registration and login flows.

#### Scenario: Successful registration creates session without publishing errors
- **GIVEN** a user completes the sign-up form with valid credentials
- **WHEN** the registration completes successfully and `createSession()` is called
- **THEN** the `currentSession` and `isAuthenticated` properties SHALL be updated within a deferred Task
- **AND** no "Publishing changes from within view updates" warnings SHALL appear in console
- **AND** the UI SHALL transition to the authenticated state immediately
- **AND** the sign-up button SHALL not become permanently disabled

#### Scenario: Session creation maintains audit logging sequence
- **GIVEN** a user successfully registers or logs in
- **WHEN** `createSession()` updates the authentication state
- **THEN** the session token SHALL be saved to keychain first
- **AND** the session object SHALL be created second
- **AND** both `currentSession` and `isAuthenticated` properties SHALL be updated together in a deferred Task
- **AND** the audit log entry SHALL be created after state updates are initiated
- **AND** the session timeout timer SHALL be started last

#### Scenario: Login flow maintains correct state publishing
- **GIVEN** an existing user attempts to log in
- **WHEN** authentication succeeds and `createSession()` is called
- **THEN** state updates SHALL follow the same deferred pattern as registration
- **AND** no SwiftUI publishing violations SHALL occur
- **AND** the login button SHALL not become permanently disabled

#### Scenario: Biometric authentication maintains correct state publishing
- **GIVEN** a user with biometric authentication enabled logs in
- **WHEN** biometric verification succeeds and `createSession()` is called
- **THEN** state updates SHALL follow the same deferred pattern as password login
- **AND** no SwiftUI publishing violations SHALL occur
- **AND** UI controls SHALL remain responsive

### Requirement: Deferred State Updates for View Cycle Safety
The authentication service SHALL defer @Published property updates to the next run loop cycle when called from view contexts to prevent publishing violations.

#### Scenario: Task wrapper defers state updates correctly
- **GIVEN** the `createSession()` method is called during a view update cycle
- **WHEN** the method updates @Published properties
- **THEN** updates SHALL be wrapped in `Task { @MainActor in }`
- **AND** updates SHALL occur in the next run loop iteration
- **AND** updates SHALL happen outside the current view update context

#### Scenario: Both session properties are updated together
- **GIVEN** `currentSession` and `isAuthenticated` are @Published properties
- **WHEN** `createSession()` needs to update both
- **THEN** both SHALL be updated within the same deferred Task
- **AND** the updates SHALL be atomic from SwiftUI's perspective
- **AND** no intermediate state SHALL be visible to views

### Requirement: MainActor Thread Safety
The authentication service's async operations SHALL execute on the main actor to ensure thread-safe UI state updates.

#### Scenario: createSession executes on main actor
- **GIVEN** the `createSession()` method is marked with `@MainActor`
- **WHEN** the method is called from any context
- **THEN** all code within SHALL execute on the main thread
- **AND** the deferred Task SHALL also execute on @MainActor
- **AND** thread safety is guaranteed for all UI state updates

#### Scenario: Session activity updates are deferred
- **GIVEN** `updateSessionActivity()` modifies the `currentSession` @Published property
- **WHEN** the method is called from any context (including notification handlers)
- **THEN** the update SHALL be deferred using `Task { @MainActor in }`
- **AND** no publishing violations SHALL occur
- **AND** session timeout timer updates SHALL be included in the deferred block

### Requirement: User Registration with Email and Password

Patient registration SHALL be performed against the Core API as the source of
truth: the app SHALL register the patient with the Core API (email + password),
and SHALL create a device-local cache record keyed by the canonical patient
identity returned by the Core API, used for offline access and PHI encryption-key
derivation. The plaintext password SHALL be sent only to the Core API over TLS
and SHALL never be logged.

#### Scenario: Successful patient registration

- **GIVEN** a new patient provides a valid email and a password meeting strength rules
- **WHEN** registration succeeds against the Core API
- **THEN** a Core API patient is created and an authentication token is returned
- **AND** a device-local cache record is created keyed by the canonical patient identity
- **AND** the authentication token is cached securely for cloud sync

#### Scenario: Registration rejected for an existing account

- **GIVEN** an email already registered in the tenant
- **WHEN** the patient attempts to register
- **THEN** registration fails with a conflict and no local cache record is created

### Requirement: Password Strength Validation
The system SHALL enforce healthcare-grade password strength requirements to protect Protected Health Information.

#### Scenario: Password meets all requirements
- **GIVEN** a user enters a password during registration
- **WHEN** the password is at least 12 characters long
- **AND** contains at least one uppercase letter
- **AND** contains at least one lowercase letter
- **AND** contains at least one number
- **AND** contains at least one special character (!@#$%^&*()_+-=[]{}|;:,.<>?)
- **THEN** the system SHALL accept the password as valid
- **AND** display a green checkmark indicator for password strength

#### Scenario: Password too short
- **GIVEN** a user enters a password less than 12 characters
- **THEN** the system SHALL display error "Password must be at least 12 characters"
- **AND** prevent form submission

#### Scenario: Password missing required character types
- **GIVEN** a user enters a password missing uppercase, lowercase, number, or special character
- **THEN** the system SHALL display specific error listing missing requirements
- **AND** prevent form submission

#### Scenario: Password confirmation mismatch
- **GIVEN** a user enters a password and confirmation password
- **WHEN** the confirmation does not match the original password
- **THEN** the system SHALL display error "Passwords do not match"
- **AND** prevent form submission

### Requirement: Email Validation
The system SHALL validate email addresses using standard RFC 5322 format validation.

#### Scenario: Valid email formats accepted
- **GIVEN** a user enters an email address
- **WHEN** the email matches standard format (local-part@domain)
- **AND** contains valid characters and domain structure
- **THEN** the system SHALL accept the email as valid
- **AND** allow form submission to proceed

#### Scenario: Invalid email formats rejected
- **GIVEN** a user enters an email without "@" symbol, missing domain, or invalid characters
- **THEN** the system SHALL display inline error "Please enter a valid email address"
- **AND** prevent form submission

### Requirement: 6-Digit Passcode as Authentication Alternative
The system SHALL provide a 6-digit numeric passcode as an alternative authentication method for users who cannot or prefer not to use biometric authentication or complex passwords.

#### Scenario: Valid passcode creation
- **GIVEN** a user chooses passcode as authentication method
- **WHEN** the user enters a 6-digit numeric passcode
- **AND** the passcode is not sequential (e.g., 123456, 654321)
- **AND** the passcode is not all repeated digits (e.g., 111111, 000000)
- **AND** the user confirms the passcode by entering it again correctly
- **THEN** the system SHALL hash the passcode using bcrypt (cost factor 12)
- **AND** encrypt the passcode hash using AES-256-GCM
- **AND** store the encrypted passcode hash in Core Data
- **AND** set `User.authMethod` to "passcode"
- **AND** log the passcode creation event in audit log
- **AND** navigate to AI chat interface

#### Scenario: Sequential passcode rejection
- **GIVEN** a user enters a sequential passcode (123456, 234567, 654321, etc.)
- **THEN** the system SHALL display error "Passcode cannot be sequential digits"
- **AND** prevent passcode creation
- **AND** prompt user to enter a different passcode

#### Scenario: Repeated digits passcode rejection
- **GIVEN** a user enters a passcode with all repeated digits (111111, 000000, etc.)
- **THEN** the system SHALL display error "Passcode cannot be all the same digit"
- **AND** prevent passcode creation
- **AND** prompt user to enter a different passcode

#### Scenario: Passcode confirmation mismatch
- **GIVEN** a user enters a passcode and confirmation passcode
- **WHEN** the confirmation does not match the original passcode
- **THEN** the system SHALL display error "Passcodes do not match"
- **AND** clear both passcode fields
- **AND** prompt user to re-enter passcode

#### Scenario: Passcode login success
- **GIVEN** a user has registered with passcode authentication
- **WHEN** the user enters the correct 6-digit passcode during login
- **THEN** the system SHALL decrypt the passcode hash from Core Data
- **AND** verify the entered passcode using bcrypt
- **AND** create an authenticated session
- **AND** log successful passcode login in audit log
- **AND** navigate to AI chat interface

#### Scenario: Incorrect passcode login
- **GIVEN** a user has registered with passcode authentication
- **WHEN** the user enters an incorrect 6-digit passcode during login
- **THEN** the system SHALL display error "Incorrect passcode"
- **AND** log failed passcode login attempt in audit log
- **AND** remain on login screen
- **AND** optionally implement rate limiting after 5 failed attempts (future enhancement)

### Requirement: Biometric Authentication Enrollment
The system SHALL prompt users to enable biometric authentication (Face ID or Touch ID) immediately after account creation, with 6-digit passcode as an alternative option.

#### Scenario: Biometric enrollment success
- **GIVEN** a user has successfully created an account
- **AND** the device supports biometric authentication
- **WHEN** the user reaches the biometric enrollment screen
- **AND** grants biometric permission
- **THEN** the system SHALL use LocalAuthentication framework to enroll biometric authentication
- **AND** store biometric enrollment status in keychain (`com.housecall.biometric-enrollment`)
- **AND** set `User.biometricEnabled` to `true` in Core Data
- **AND** log the biometric enrollment event in audit log
- **AND** navigate the user to the AI chat interface

#### Scenario: Biometric not available on device
- **GIVEN** a user has successfully created an account
- **AND** the device does not support biometric authentication (no Face ID/Touch ID)
- **WHEN** the user reaches the biometric enrollment screen
- **THEN** the system SHALL display message "Biometric authentication not available on this device"
- **AND** offer "Continue with Password Only" option
- **AND** navigate the user to the AI chat interface when they continue
- **AND** log the biometric unavailability event in audit log

#### Scenario: User declines biometric enrollment
- **GIVEN** a user has successfully created an account
- **AND** the device supports biometric authentication
- **WHEN** the user declines biometric enrollment
- **THEN** the system SHALL display option "Use 6-Digit Passcode Instead"
- **AND** navigate to passcode setup screen if user selects passcode
- **AND** log the biometric decline event in audit log
- **AND** navigate to AI chat interface if user chooses to continue with password-only

### Requirement: User Login with Multiple Authentication Methods

Patient login SHALL authenticate against the Core API as the source of truth.
On success the app SHALL cache the returned authentication token, ensure the
device-local cache record for the canonical patient identity exists, unlock PHI
encryption for that identity, and start a session. When the Core API rejects the
credentials the login SHALL fail. Biometric unlock SHALL continue to gate access
to a previously authenticated local session.

#### Scenario: Successful cloud login

- **GIVEN** valid credentials and a reachable Core API
- **WHEN** the patient logs in
- **THEN** the Core API returns an authentication token which is cached securely
- **AND** the session starts and PHI encryption is unlocked for the canonical patient identity

#### Scenario: Invalid credentials are rejected

- **GIVEN** a reachable Core API and incorrect credentials
- **WHEN** the patient attempts to log in
- **THEN** login fails and no session is started

### Requirement: Session Management
The system SHALL manage authenticated user sessions with automatic timeout and re-authentication requirements.

#### Scenario: Active session maintained
- **GIVEN** a user is logged in
- **WHEN** the user interacts with the app (any tap, swipe, or input)
- **THEN** the system SHALL reset the inactivity timer to 5 minutes
- **AND** maintain the authenticated session token in keychain

#### Scenario: Session timeout after inactivity
- **GIVEN** a user is logged in
- **WHEN** 5 minutes pass without any user interaction
- **THEN** the system SHALL invalidate the session token in keychain
- **AND** log the session timeout event in audit log
- **AND** navigate the user to the login screen
- **AND** display message "Your session has expired for security. Please log in again."

#### Scenario: Explicit logout
- **GIVEN** a user is logged in
- **WHEN** the user selects "Logout" from settings or menu
- **THEN** the system SHALL invalidate the session token in keychain
- **AND** log the logout event in audit log
- **AND** navigate the user to the login screen

#### Scenario: App backgrounded security
- **GIVEN** a user is logged in and using the app
- **WHEN** the app moves to background (user switches apps or locks device)
- **THEN** the system SHALL start a 5-minute background timer
- **AND** when app returns to foreground after timeout, require re-authentication
- **AND** log the background security event in audit log

### Requirement: Authentication State Persistence
The system SHALL persist authentication state across app launches using secure keychain storage.

#### Scenario: User remains logged in across app launches
- **GIVEN** a user successfully logged in and session token exists in keychain
- **WHEN** the user closes and reopens the app within 5 minutes
- **AND** the session has not expired
- **THEN** the system SHALL validate the session token from keychain
- **AND** navigate directly to the AI chat interface without requiring re-login
- **AND** log the session resumption event in audit log

#### Scenario: Expired session on app launch
- **GIVEN** a user previously logged in but session expired
- **WHEN** the user opens the app
- **THEN** the system SHALL detect the expired session token
- **AND** remove the invalid token from keychain
- **AND** navigate to the login screen
- **AND** display message "Please log in to continue"

#### Scenario: First app launch (no account)
- **GIVEN** the app is launched for the first time on a device
- **WHEN** no user account exists in Core Data
- **AND** no session token exists in keychain
- **THEN** the system SHALL navigate to the registration screen
- **AND** display welcome message for new users

### Requirement: Accessibility Compliance
The system SHALL provide authentication interfaces that meet WCAG 2.1 AA accessibility standards.

#### Scenario: VoiceOver support for registration
- **GIVEN** a user has VoiceOver enabled
- **WHEN** the user navigates the registration screen
- **THEN** the system SHALL provide descriptive labels for email, password, and name fields
- **AND** announce validation errors clearly
- **AND** indicate password strength requirements audibly
- **AND** provide accessible hints for form completion

#### Scenario: Dynamic Type support
- **GIVEN** a user has increased text size in iOS settings
- **WHEN** the user views authentication screens
- **THEN** the system SHALL scale all text and UI elements according to Dynamic Type settings
- **AND** maintain readable layout without truncation or overlap

#### Scenario: High contrast mode support
- **GIVEN** a user has enabled high contrast mode
- **WHEN** the user views authentication screens
- **THEN** the system SHALL provide sufficient contrast ratios for all text and interactive elements
- **AND** clearly distinguish input fields, buttons, and validation messages

### Requirement: Error Handling and Recovery
The system SHALL handle all authentication errors gracefully without exposing sensitive information or crashing.

#### Scenario: Core Data save failure during registration
- **GIVEN** a user completes registration form correctly
- **WHEN** Core Data fails to save the user entity (disk full, corruption, etc.)
- **THEN** the system SHALL display user-friendly error "Unable to create account. Please try again."
- **AND** log the detailed error in audit log with error code and description
- **AND** SHALL NOT crash with `fatalError()`
- **AND** remain on registration screen with form data preserved

#### Scenario: Keychain write failure
- **GIVEN** the system attempts to store encryption key or session token in keychain
- **WHEN** keychain write operation fails (keychain locked, access denied, etc.)
- **THEN** the system SHALL display error "Security setup failed. Please ensure device is unlocked and try again."
- **AND** log the keychain error in audit log
- **AND** roll back user account creation if key storage fails
- **AND** SHALL NOT proceed with authentication

#### Scenario: Encryption operation failure
- **GIVEN** the system attempts to encrypt user data during registration
- **WHEN** CryptoKit encryption fails (invalid key, memory error, etc.)
- **THEN** the system SHALL display error "Security setup failed. Please try again."
- **AND** log the encryption error with details in audit log
- **AND** roll back user account creation
- **AND** SHALL NOT store unencrypted data

#### Scenario: Biometric framework unavailable
- **GIVEN** the system attempts to initialize LocalAuthentication
- **WHEN** the framework is unavailable or returns an error
- **THEN** the system SHALL gracefully skip biometric enrollment
- **AND** proceed with password-only authentication
- **AND** log the framework error in audit log
- **AND** inform user "Biometric authentication temporarily unavailable"

### Requirement: Core API Session Token Lifecycle

The app SHALL cache the Core API authentication token in the Keychain on
successful registration or login, SHALL clear it on logout, and SHALL deactivate
cloud sync and require re-login when the Core API reports the token is no longer
valid. The token SHALL never be logged.

#### Scenario: Token cached and cleared

- **GIVEN** a successful Core API login
- **WHEN** the token is returned
- **THEN** it is stored in the Keychain for cloud sync
- **WHEN** the patient logs out
- **THEN** the cached token is removed

#### Scenario: Expired token forces re-login

- **GIVEN** a cached token that the Core API rejects as invalid
- **WHEN** a cloud sync request returns unauthorized
- **THEN** cloud sync is deactivated and re-login is required, without a retry loop

### Requirement: Offline Authentication Fallback

The app SHALL allow a previously-authenticated patient to unlock their encrypted
local record via the cached local credential when the Core API is unreachable
(network failure or timeout, as distinct from a credential rejection), and SHALL
keep cloud sync inactive until a valid token is obtained.

#### Scenario: Login while Core API unreachable

- **GIVEN** a patient who has previously authenticated on this device
- **AND** the Core API is unreachable
- **WHEN** the patient logs in with correct credentials
- **THEN** the local encrypted record is unlocked for offline use
- **AND** cloud sync remains inactive until connectivity and a valid token return

#### Scenario: Unreachable is distinguished from rejected

- **GIVEN** the Core API is reachable and rejects the credentials
- **WHEN** the patient attempts to log in
- **THEN** login fails and the offline fallback is NOT used

