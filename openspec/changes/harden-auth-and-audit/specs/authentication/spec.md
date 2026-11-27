# authentication (delta)

## MODIFIED Requirements

### Requirement: Core API Session Token Lifecycle

The app SHALL cache the Core API access token and refresh token in the Keychain
on successful registration or login, SHALL revoke and clear them on logout, and
SHALL, when the Core API reports the access token is no longer valid, attempt
one refresh before deactivating cloud sync and requiring the patient to sign in
again. Neither token SHALL ever be logged.

#### Scenario: Tokens cached and cleared

- **GIVEN** a successful Core API login
- **WHEN** the tokens are returned
- **THEN** both are stored in the Keychain for cloud sync
- **WHEN** the patient logs out
- **THEN** the refresh token is revoked with the Core API and both tokens are removed

#### Scenario: Expired access token refreshes silently

- **GIVEN** a cached access token that has expired and a valid refresh token
- **WHEN** a cloud sync request returns unauthorized
- **THEN** the app refreshes once and retries the request with the new access token
- **AND** the patient is not asked to sign in

#### Scenario: Failed refresh forces re-login

- **GIVEN** a cached access token that the Core API rejects and a refresh token that is also rejected
- **WHEN** a cloud sync request returns unauthorized
- **THEN** cloud sync is deactivated and re-login is required, without a retry loop
