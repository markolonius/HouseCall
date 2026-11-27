# ios-cloud-sync (delta)

## ADDED Requirements

### Requirement: Authenticated Cloud Activation

Cloud sync SHALL activate only when a Core API base URL and tenant are configured
AND a valid Core API authentication token is present. After a successful patient
login that yields a token, the client SHALL activate cloud sync so patient
messages route through the Core API and agent interview questions and delivered
recommendations arrive over the live connection. Absent configuration or token,
the client SHALL remain in local-only mode with no regression.

#### Scenario: Cloud activates after authenticated login

- **GIVEN** a configured Core API base URL and tenant
- **WHEN** the patient logs in and a valid token is cached
- **THEN** cloud sync activates and patient messages route through the Core API
- **AND** agent interview questions arrive over the live connection

#### Scenario: Local-only mode without configuration or token

- **GIVEN** no Core API tenant/base URL configured, or no valid token
- **WHEN** the patient uses the chat
- **THEN** cloud sync stays inactive and the app operates in local-only mode without error
