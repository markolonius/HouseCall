# authentication (delta)

## MODIFIED Requirements

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

## ADDED Requirements

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
