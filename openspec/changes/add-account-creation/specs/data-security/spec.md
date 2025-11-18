# Specification: Data Security

## ADDED Requirements

### Requirement: HIPAA-Compliant Encryption at Rest
The system SHALL encrypt all Protected Health Information (PHI) stored in Core Data using AES-256-GCM encryption to comply with HIPAA Security Rule 45 CFR § 164.312(a)(2)(iv).

#### Scenario: User data encrypted before Core Data storage
- **GIVEN** the system creates or updates a User entity
- **WHEN** storing email, password hash, or full name
- **THEN** the system SHALL encrypt each field using AES-256-GCM with a user-specific derived key
- **AND** generate a random 96-bit nonce for each encryption operation
- **AND** store the encrypted data as `Data` type in Core Data
- **AND** store the nonce alongside encrypted data for decryption

#### Scenario: Core Data persistent store file protection
- **GIVEN** the system initializes the Core Data stack
- **WHEN** configuring `NSPersistentStoreDescription`
- **THEN** the system SHALL set file protection to `NSFileProtectionComplete`
- **AND** enable encryption at the iOS filesystem level
- **AND** ensure data is inaccessible when device is locked

#### Scenario: Successful decryption of user data
- **GIVEN** an encrypted User entity exists in Core Data
- **WHEN** the system needs to read email, password hash, or full name
- **THEN** the system SHALL retrieve the user-specific derived key from EncryptionManager
- **AND** decrypt the data using AES-256-GCM with stored nonce
- **AND** verify authentication tag to detect tampering
- **AND** return plaintext data to the caller

#### Scenario: Decryption failure due to tampering
- **GIVEN** an encrypted field in Core Data has been modified outside the app
- **WHEN** the system attempts to decrypt the data
- **AND** authentication tag verification fails
- **THEN** the system SHALL throw a `CryptoKitError.authenticationFailure` error
- **AND** log the tampering detection event in audit log with user ID and field name
- **AND** display security alert "Data integrity check failed. Please contact support."
- **AND** prevent access to compromised account

### Requirement: Master Encryption Key Management
The system SHALL generate and securely store a master encryption key in iOS Keychain with device-bound protection.

#### Scenario: Master key generation on first launch
- **GIVEN** the app is launched for the first time on a device
- **WHEN** no master encryption key exists in keychain
- **THEN** the system SHALL generate a random 256-bit symmetric key using `SymmetricKey.init(size: .bits256)`
- **AND** store the key in keychain with identifier `com.housecall.master-encryption-key`
- **AND** set accessibility to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- **AND** set `kSecAttrSynchronizable` to `false` (no iCloud sync)
- **AND** log the master key generation event in audit log

#### Scenario: Master key retrieval for existing installation
- **GIVEN** a master encryption key exists in keychain
- **WHEN** the app launches or EncryptionManager is initialized
- **THEN** the system SHALL retrieve the master key from keychain
- **AND** verify the key is 256 bits in length
- **AND** cache the key in memory during app session (secured memory only)
- **AND** use the key for deriving user-specific encryption keys

#### Scenario: Master key inaccessible when device locked
- **GIVEN** the device is locked
- **WHEN** the system attempts to retrieve the master key from keychain
- **THEN** keychain SHALL return `errSecInteractionNotAllowed` error
- **AND** the system SHALL gracefully handle the error
- **AND** display message "Please unlock your device to access HouseCall"
- **AND** NOT crash or expose sensitive error details

#### Scenario: User-specific key derivation
- **GIVEN** a master encryption key exists in keychain
- **WHEN** the system needs to encrypt or decrypt data for a specific user
- **THEN** the system SHALL derive a user-specific key using HKDF (HMAC-based Key Derivation Function)
- **AND** use the master key as the input key material
- **AND** use the user's UUID as the salt (unique per user)
- **AND** generate a 256-bit derived key for AES-256-GCM operations
- **AND** cache derived keys in memory during the user's session

### Requirement: Secure Keychain Storage for Credentials
The system SHALL store authentication-related secrets in iOS Keychain with appropriate access controls.

#### Scenario: Session token storage after login
- **GIVEN** a user successfully authenticates
- **WHEN** the system creates a new session
- **THEN** the system SHALL generate a unique session token (UUID)
- **AND** store the token in keychain with identifier `com.housecall.session-token`
- **AND** set accessibility to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- **AND** associate the token with the user's UUID
- **AND** set a 5-minute expiration timestamp

#### Scenario: Session token retrieval on app launch
- **GIVEN** a session token exists in keychain
- **WHEN** the app launches
- **THEN** the system SHALL retrieve the session token from keychain
- **AND** verify the token has not expired (timestamp check)
- **AND** validate the associated user exists in Core Data
- **AND** allow automatic login if valid
- **AND** delete the token if expired or invalid

#### Scenario: Biometric enrollment flag storage
- **GIVEN** a user completes biometric enrollment
- **WHEN** the system records biometric setup
- **THEN** the system SHALL store a boolean flag in keychain with identifier `com.housecall.biometric-enrollment`
- **AND** associate the flag with the user's UUID
- **AND** set accessibility to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`

#### Scenario: Keychain cleanup on logout
- **GIVEN** a user explicitly logs out or session expires
- **WHEN** the system terminates the session
- **THEN** the system SHALL delete the session token from keychain
- **AND** clear cached derived encryption keys from memory
- **AND** NOT delete the master encryption key (persists across sessions)
- **AND** log the keychain cleanup event in audit log

### Requirement: Password Hashing with Bcrypt
The system SHALL hash user passwords using bcrypt with cost factor 12 before encryption and storage.

#### Scenario: Password hashing during registration
- **GIVEN** a user provides a password during account creation
- **WHEN** the system processes the password for storage
- **THEN** the system SHALL hash the password using bcrypt algorithm
- **AND** use cost factor 12 (2^12 iterations)
- **AND** generate a random salt unique to this password
- **AND** produce a bcrypt hash string (60 characters)
- **AND** encrypt the bcrypt hash with AES-256-GCM before Core Data storage
- **AND** discard the plaintext password from memory immediately

#### Scenario: Password verification during login
- **GIVEN** a user enters a password during login
- **WHEN** the system validates the password
- **THEN** the system SHALL retrieve the encrypted password hash from Core Data
- **AND** decrypt the hash using the user's derived encryption key
- **AND** verify the entered password against the bcrypt hash
- **AND** return authentication success if passwords match
- **AND** discard the plaintext password from memory immediately

#### Scenario: Bcrypt cost factor prevents brute force
- **GIVEN** an attacker attempts to brute force passwords
- **WHEN** hashing each password guess with bcrypt cost factor 12
- **THEN** each hash operation SHALL take approximately 250-500ms
- **AND** effectively rate-limit brute force attempts
- **AND** make large-scale password cracking computationally infeasible

### Requirement: Audit Logging for HIPAA Compliance
The system SHALL log all authentication and data access events in an encrypted audit trail to comply with HIPAA Security Rule 45 CFR § 164.312(b).

#### Scenario: Account creation event logged
- **GIVEN** a user successfully creates an account
- **WHEN** the account is saved to Core Data
- **THEN** the system SHALL create an `AuditLogEntry` with:
  - `eventType`: "account_created"
  - `userId`: new user's UUID
  - `timestamp`: current date/time with millisecond precision
  - `deviceId`: unique device identifier
  - `encryptedDetails`: JSON with email (hashed), registration method
- **AND** encrypt the details field with AES-256-GCM
- **AND** save the audit entry to Core Data

#### Scenario: Login attempt logged
- **GIVEN** a user attempts to log in
- **WHEN** authentication completes (success or failure)
- **THEN** the system SHALL create an `AuditLogEntry` with:
  - `eventType`: "login_success" or "login_failure"
  - `userId`: user's UUID (if account exists)
  - `timestamp`: current date/time
  - `deviceId`: unique device identifier
  - `encryptedDetails`: JSON with authentication method (password, biometric), failure reason if applicable
- **AND** encrypt the details field
- **AND** save the audit entry to Core Data

#### Scenario: Biometric enrollment logged
- **GIVEN** a user completes biometric enrollment
- **WHEN** the enrollment status is saved
- **THEN** the system SHALL create an `AuditLogEntry` with:
  - `eventType`: "biometric_enrolled" or "biometric_declined"
  - `userId`: user's UUID
  - `timestamp`: current date/time
  - `deviceId`: unique device identifier
  - `encryptedDetails`: JSON with biometric type (Face ID, Touch ID), device model
- **AND** save the encrypted audit entry

#### Scenario: Session timeout logged
- **GIVEN** a user's session expires due to inactivity
- **WHEN** the session is invalidated
- **THEN** the system SHALL create an `AuditLogEntry` with:
  - `eventType`: "session_timeout"
  - `userId`: user's UUID
  - `timestamp`: current date/time
  - `deviceId`: unique device identifier
  - `encryptedDetails`: JSON with inactivity duration, last activity timestamp
- **AND** save the encrypted audit entry

#### Scenario: Data integrity failure logged
- **GIVEN** the system detects data tampering during decryption
- **WHEN** authentication tag verification fails
- **THEN** the system SHALL create an `AuditLogEntry` with:
  - `eventType`: "security_alert_tampering"
  - `userId`: affected user's UUID
  - `timestamp`: current date/time
  - `deviceId`: unique device identifier
  - `encryptedDetails`: JSON with field name, error code, action taken
- **AND** save the audit entry immediately
- **AND** flag the entry for security review

#### Scenario: Audit log query for compliance
- **GIVEN** a compliance officer needs to review authentication events
- **WHEN** querying the audit log
- **THEN** the system SHALL retrieve `AuditLogEntry` entities from Core Data
- **AND** filter by event type, user ID, or date range as requested
- **AND** decrypt the `encryptedDetails` field for authorized review
- **AND** present events in chronological order
- **AND** include all required HIPAA audit elements (who, what, when, where)

### Requirement: Secure Memory Handling
The system SHALL minimize exposure of sensitive data in memory and clear sensitive data after use.

#### Scenario: Password cleared from memory after hashing
- **GIVEN** a user enters a password during registration or login
- **WHEN** the password is hashed or verified
- **THEN** the system SHALL overwrite the plaintext password string in memory with zeros
- **AND** release the password variable immediately
- **AND** NOT store plaintext passwords in any logs, error messages, or analytics

#### Scenario: Encryption keys cached securely during session
- **GIVEN** the system derives a user-specific encryption key
- **WHEN** caching the key for performance
- **THEN** the system SHALL store the key in a secure memory region (if available)
- **AND** clear the cached key when the user logs out or app terminates
- **AND** NOT persist cached keys to disk or UserDefaults

#### Scenario: Sensitive data not logged or debugged
- **GIVEN** the system processes passwords, encryption keys, or PHI
- **WHEN** logging events or errors
- **THEN** the system SHALL NOT include plaintext passwords, keys, or PHI in log messages
- **AND** redact sensitive fields in error descriptions
- **AND** use placeholders like "[REDACTED]" for sensitive data in logs

### Requirement: Encryption Performance and Optimization
The system SHALL perform encryption operations efficiently to maintain responsive user experience while ensuring security.

#### Scenario: Encryption operation completes within performance budget
- **GIVEN** the system encrypts a user field (email, name, password hash)
- **WHEN** performing AES-256-GCM encryption
- **THEN** the operation SHALL complete in less than 50 milliseconds
- **AND** NOT block the main thread (use background queue if needed)
- **AND** maintain 60 FPS UI responsiveness during registration

#### Scenario: Derived key caching reduces redundant operations
- **GIVEN** multiple encryption operations for the same user during a session
- **WHEN** the system needs the user-specific derived key
- **THEN** the system SHALL retrieve the cached key from memory
- **AND** NOT re-derive the key for each operation
- **AND** reduce HKDF operations by caching
- **AND** clear cache on logout or session expiration

#### Scenario: Background encryption for non-blocking UI
- **GIVEN** the system performs Core Data save with encrypted fields
- **WHEN** encryption involves multiple fields or large data
- **THEN** the system SHALL perform encryption on a background queue
- **AND** update the UI on the main thread after completion
- **AND** display loading indicator during encryption
- **AND** ensure UI remains responsive

### Requirement: Error Handling for Security Operations
The system SHALL handle all cryptographic and security errors without exposing sensitive information or crashing.

#### Scenario: Encryption failure handled gracefully
- **GIVEN** the system attempts to encrypt user data
- **WHEN** CryptoKit returns an error (invalid key, insufficient memory, etc.)
- **THEN** the system SHALL catch the error
- **AND** log the error details in audit log (without sensitive data)
- **AND** display user-friendly message "Security setup failed. Please try again."
- **AND** roll back the user creation transaction
- **AND** NOT crash or use `fatalError()`

#### Scenario: Keychain access denied
- **GIVEN** the system attempts to read or write keychain
- **WHEN** keychain returns access denied error (device locked, passcode disabled, etc.)
- **THEN** the system SHALL display message "Keychain access requires device passcode. Please enable passcode in Settings."
- **AND** log the keychain error in audit log
- **AND** prevent account creation or login until keychain is accessible
- **AND** provide actionable guidance to the user

#### Scenario: Master key corruption detected
- **GIVEN** the master encryption key is retrieved from keychain
- **WHEN** the key is invalid (wrong size, corrupted data, etc.)
- **THEN** the system SHALL log a critical security alert in audit log
- **AND** display error "Encryption key corrupted. App data may be inaccessible. Contact support."
- **AND** prevent further operations that require the key
- **AND** NOT attempt automatic key regeneration (would lose access to existing data)

#### Scenario: Core Data decryption error recovery
- **GIVEN** the system attempts to decrypt a user field from Core Data
- **WHEN** decryption fails (wrong key, corrupted data, tampering detected)
- **THEN** the system SHALL log the specific error in audit log
- **AND** mark the affected user account as "security_locked"
- **AND** display message "Account security verification failed. Please contact support."
- **AND** prevent login for the affected account
- **AND** allow creation of new accounts (master key still valid)
