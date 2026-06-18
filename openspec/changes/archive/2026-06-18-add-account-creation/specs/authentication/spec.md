# Specification: User Authentication

## ADDED Requirements

### Requirement: User Registration with Email and Password
The system SHALL provide a user registration interface that collects email address, password, and full name to create a new account.

#### Scenario: Successful account creation
- **GIVEN** a new user opens the registration screen
- **WHEN** the user enters a valid email, strong password, and full name
- **AND** confirms the password correctly
- **AND** email is not already registered
- **THEN** the system SHALL create an encrypted user account in Core Data
- **AND** store the master encryption key in keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- **AND** encrypt the password hash using bcrypt (cost factor 12) then AES-256-GCM
- **AND** encrypt the full name using AES-256-GCM with user-specific derived key
- **AND** log the account creation event in the audit log
- **AND** navigate the user to biometric enrollment screen

#### Scenario: Duplicate email rejection
- **GIVEN** an email address is already registered in Core Data
- **WHEN** a user attempts to register with that email
- **THEN** the system SHALL display error "An account with this email already exists"
- **AND** SHALL NOT create a duplicate user record
- **AND** log the failed registration attempt in audit log

#### Scenario: Invalid email format
- **GIVEN** a user enters an invalid email format (e.g., "notanemail", "missing@domain")
- **WHEN** the user attempts to submit the registration form
- **THEN** the system SHALL display inline validation error "Please enter a valid email address"
- **AND** SHALL NOT proceed with registration

#### Scenario: Weak password rejection
- **GIVEN** a user enters a password that does not meet strength requirements
- **WHEN** the user attempts to submit the registration form
- **THEN** the system SHALL display inline validation error with specific requirements not met
- **AND** SHALL NOT proceed with registration

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
The system SHALL provide a login interface that authenticates users with their chosen authentication method (password, passcode, or biometric).

#### Scenario: Successful login with biometric enabled
- **GIVEN** a registered user with biometric authentication enabled
- **WHEN** the user enters correct email and password
- **AND** successfully completes biometric verification (Face ID/Touch ID)
- **THEN** the system SHALL decrypt the user's encryption key from keychain
- **AND** create an authenticated session token stored in keychain
- **AND** update `User.lastLoginAt` timestamp
- **AND** log the successful login event in audit log
- **AND** navigate to the AI chat interface

#### Scenario: Successful login without biometric (password-only)
- **GIVEN** a registered user without biometric authentication enabled
- **WHEN** the user enters correct email and password
- **THEN** the system SHALL decrypt the user's encryption key from keychain
- **AND** create an authenticated session token stored in keychain
- **AND** update `User.lastLoginAt` timestamp
- **AND** log the successful login event in audit log
- **AND** navigate to the AI chat interface

#### Scenario: Invalid credentials
- **GIVEN** a user attempts to log in
- **WHEN** the email exists but password is incorrect
- **THEN** the system SHALL display error "Invalid email or password"
- **AND** SHALL NOT reveal which credential is incorrect (security best practice)
- **AND** log the failed login attempt in audit log with reason "invalid_password"
- **AND** remain on login screen

#### Scenario: Non-existent account
- **GIVEN** a user attempts to log in
- **WHEN** the email does not exist in Core Data
- **THEN** the system SHALL display error "Invalid email or password"
- **AND** log the failed login attempt in audit log with reason "account_not_found"
- **AND** remain on login screen

#### Scenario: Biometric authentication failure
- **GIVEN** a registered user with biometric enabled
- **WHEN** the user enters correct email and password
- **AND** biometric verification fails (wrong face/fingerprint)
- **THEN** the system SHALL display error "Biometric authentication failed"
- **AND** offer "Try Again" or "Use Password Only" options
- **AND** log the failed biometric attempt in audit log
- **AND** allow retry with password-only fallback

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
