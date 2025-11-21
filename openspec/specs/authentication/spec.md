# Authentication Capability Specification

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
