# physician-web-app (delta)

## MODIFIED Requirements

### Requirement: Physician Authentication

The physician web app SHALL require a physician to authenticate with a password
and a time-based one-time code before any patient data or recommendation is
shown. An unauthenticated request SHALL be redirected to the login form.
Sessions SHALL be stored server-side, SHALL end after 30 minutes of inactivity
or 12 hours after login, and SHALL be revoked on logout. A physician without an
enrolled second factor SHALL be required to enrol one before seeing patient
data.

#### Scenario: Unauthenticated access is redirected

**Given** an unauthenticated browser session
**When** the session requests the panel or the review queue
**Then** the request is redirected to the login form
**And** no patient data is rendered

#### Scenario: A physician logs in

**Given** a physician with valid credentials and an enrolled second factor
**When** the physician submits the login form and then a valid one-time code
**Then** a session is established that carries the physician's identity and tenant

#### Scenario: Password alone does not show patient data

**Given** a physician who has submitted a valid password but no one-time code
**When** the session requests the review queue
**Then** the physician is sent to the one-time-code step
**And** no patient data is rendered

#### Scenario: First login requires enrolment

**Given** a physician with no enrolled second factor
**When** the physician logs in with a valid password
**Then** the physician must enrol an authenticator and confirm a code before any patient data is shown

#### Scenario: An idle session expires

**Given** a physician session with no activity for 30 minutes
**When** the physician requests any page
**Then** the session is ended and the physician is redirected to the login form

## ADDED Requirements

### Requirement: Portal Response Hardening

Every physician web app response SHALL carry a restrictive
Content-Security-Policy, `X-Content-Type-Options: nosniff` and
`Referrer-Policy: no-referrer`; pages containing patient data SHALL carry
`Cache-Control: no-store`; and responses served over HTTPS SHALL carry
Strict-Transport-Security. Every state-changing form submission SHALL carry a
per-session CSRF token, and a missing or wrong token SHALL be rejected.

#### Scenario: A patient-data page is not cached

**Given** an authenticated physician
**When** the review queue is served
**Then** the response carries `Cache-Control: no-store` and the security headers

#### Scenario: A forged review submission is rejected

**Given** a review action POST without a valid CSRF token
**When** it reaches the web app
**Then** it is rejected with 403
**And** the recommendation is unchanged
