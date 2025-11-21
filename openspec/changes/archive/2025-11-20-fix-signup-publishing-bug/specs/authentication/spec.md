# Authentication Capability - Delta Specification

## MODIFIED Requirements

### Requirement: Session Creation State Management
The authentication service SHALL manage session state updates synchronously on the main actor to prevent SwiftUI publishing violations during registration and login flows.

#### Scenario: Successful registration creates session without publishing errors
- **GIVEN** a user completes the sign-up form with valid credentials
- **WHEN** the registration completes successfully and `createSession()` is called
- **THEN** the `isAuthenticated` property SHALL be updated synchronously on the main thread
- **AND** no "Publishing changes from within view updates" warnings SHALL appear in console
- **AND** the UI SHALL transition to the authenticated state immediately
- **AND** the sign-up button SHALL not become permanently disabled

#### Scenario: Session creation maintains audit logging sequence
- **GIVEN** a user successfully registers or logs in
- **WHEN** `createSession()` updates the authentication state
- **THEN** the session token SHALL be saved to keychain first
- **AND** the session object SHALL be created second
- **AND** the `currentSession` property SHALL be updated third
- **AND** the `isAuthenticated` property SHALL be updated fourth (synchronously on @MainActor)
- **AND** the audit log entry SHALL be created after all state updates
- **AND** the session timeout timer SHALL be started last

#### Scenario: Login flow maintains correct state publishing
- **GIVEN** an existing user attempts to log in
- **WHEN** authentication succeeds and `createSession()` is called
- **THEN** state updates SHALL follow the same synchronous pattern as registration
- **AND** no SwiftUI publishing violations SHALL occur
- **AND** the login button SHALL not become permanently disabled

#### Scenario: Biometric authentication maintains correct state publishing
- **GIVEN** a user with biometric authentication enabled logs in
- **WHEN** biometric verification succeeds and `createSession()` is called
- **THEN** state updates SHALL follow the same synchronous pattern as password login
- **AND** no SwiftUI publishing violations SHALL occur
- **AND** UI controls SHALL remain responsive

### Requirement: MainActor Thread Safety
The authentication service's async operations SHALL execute on the main actor to ensure thread-safe UI state updates.

#### Scenario: createSession executes on main actor
- **GIVEN** the `createSession()` method is marked with `@MainActor`
- **WHEN** the method is called from any context
- **THEN** all code within SHALL execute on the main thread
- **AND** all `@Published` property updates SHALL occur synchronously
- **AND** no additional dispatch queue wrapping SHALL be needed

#### Scenario: Published property updates are synchronous
- **GIVEN** `isAuthenticated` is a `@Published` property in an `ObservableObject`
- **WHEN** it is updated within a `@MainActor` method
- **THEN** the update SHALL occur immediately on the main thread
- **AND** SwiftUI views SHALL receive the update in the correct update cycle
- **AND** no asynchronous dispatch SHALL defer the update
