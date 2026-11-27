# ios-cloud-sync (delta)

## MODIFIED Requirements

### Requirement: Authenticated Cloud Activation

Cloud sync SHALL activate when the Core API base URL and tenant are configured
AND a valid Core API authentication token is present. After a successful patient
login that yields a token, the client SHALL activate cloud sync so patient
messages route through the Core API and agent interview questions and delivered
recommendations arrive over the live connection. The Core API SHALL be the only
path by which a patient message leaves the device: when no valid token is
present the client SHALL show cached conversation history read-only, disable
message input, and prompt the patient to sign in. The client SHALL NOT call a
model endpoint directly under any condition.

#### Scenario: Cloud activates after authenticated login

- **GIVEN** a configured Core API base URL and tenant
- **WHEN** the patient logs in and a valid token is cached
- **THEN** cloud sync activates and patient messages route through the Core API
- **AND** agent interview questions arrive over the live connection

#### Scenario: Expired token makes the chat read-only

- **GIVEN** a patient whose cached token the Core API rejects as invalid
- **WHEN** the patient opens the chat
- **THEN** previously synced messages are shown
- **AND** message input is disabled with a prompt to sign in
- **AND** no message is sent to any endpoint other than the Core API

#### Scenario: Signing in again reactivates sync

- **GIVEN** the chat is read-only because the token was rejected
- **WHEN** the patient signs in successfully
- **THEN** cloud sync activates and message input is re-enabled without restarting the app

## ADDED Requirements

### Requirement: Core API Configuration Required

The app SHALL require a configured Core API base URL and tenant to create or
sign in to an account. A build without that configuration SHALL show a
configuration error on the sign-in screen and SHALL NOT create local-only
accounts.

#### Scenario: Unconfigured build cannot create accounts

- **GIVEN** a build with no Core API base URL or tenant configured
- **WHEN** the sign-in screen is shown
- **THEN** a configuration error is displayed
- **AND** registration and login are unavailable
- **AND** no local account record is created
