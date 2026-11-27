# core-api (delta)

## MODIFIED Requirements

### Requirement: Authenticated API Access

The Core API SHALL require a valid signed access token on every `/api` request
other than login, registration and refresh. Access tokens SHALL expire 15
minutes after issue, SHALL carry the caller's `tenant_id`, actor identity and a
`patient-api` audience, and middleware SHALL reject any missing, malformed,
expired or wrong-audience token. The WebSocket connection SHALL be
authenticated by a connection ticket, not by an access token in the URL.

#### Scenario: Missing or invalid token is rejected

**Given** a request to a Core API endpoint
**When** the request has no token, a malformed token, an expired token, or a token for another audience
**Then** the Core API responds with an unauthorized status
**And** no handler logic runs

#### Scenario: Valid token establishes tenant and actor context

**Given** a request with a valid access token for a patient in tenant A
**When** the request reaches a handler
**Then** the handler operates with `tenant_id` A and that patient's identity
**And** the caller cannot act outside that tenant or identity

#### Scenario: An access token in the WebSocket URL is refused

**Given** a client opening the WebSocket with `?token=` and no ticket
**When** the upgrade is attempted
**Then** the Core API refuses the connection

### Requirement: Audit Logging

The Core API SHALL write an append-only `AuditEvent` for every operation that
touches PHI — message ingestion, agent interaction, every recommendation state
transition, and every read of a patient's messages or recommendations. Audit
events SHALL contain metadata and identifiers only, never PHI content.

#### Scenario: A PHI-touching operation produces an audit event

**Given** any operation that creates or transitions a PHI record
**When** the operation completes
**Then** an `AuditEvent` is written with the event type, actor id, and tenant
**And** the audit event contains no message or recommendation content

#### Scenario: A PHI read produces an audit event

**Given** an authenticated actor
**When** the actor reads a patient's messages or a recommendation
**Then** a `phi_read` audit event is written with the actor, tenant, resource type, resource id and patient id
**And** the event contains no message or recommendation content

## ADDED Requirements

### Requirement: Refresh Token Rotation

The Core API SHALL issue a refresh token with every patient login and
registration, store only its hash, and exchange it once for a new access token
and a new refresh token. Presenting a refresh token that was already used SHALL
revoke every token descended from the same login and write an audit event.
Logout SHALL revoke the presented refresh token's family.

#### Scenario: A refresh token rotates

**Given** a patient with a valid, unused refresh token
**When** the patient calls the refresh endpoint with it
**Then** a new access token and a new refresh token are returned
**And** the presented refresh token can no longer be used

#### Scenario: Reuse revokes the family

**Given** a refresh token that has already been exchanged
**When** it is presented again
**Then** the request is rejected
**And** every refresh token from the same login is revoked
**And** an audit event records the reuse

#### Scenario: Logout revokes refresh

**Given** a signed-in patient
**When** the patient logs out
**Then** the patient's refresh token family is revoked

### Requirement: WebSocket Connection Tickets

The Core API SHALL issue, to an authenticated patient, a random WebSocket
connection ticket that is valid for 30 seconds and for a single connection, and
SHALL accept a WebSocket upgrade only with a valid unused ticket.

#### Scenario: A ticket opens one connection

**Given** a patient who obtained a ticket less than 30 seconds ago
**When** the patient opens the WebSocket with that ticket
**Then** the connection is established for that patient and tenant

#### Scenario: A used or expired ticket is refused

**Given** a ticket that was already used or was issued more than 30 seconds ago
**When** a WebSocket upgrade presents it
**Then** the connection is refused

### Requirement: Request Rate Limiting

The Core API SHALL limit request rates on login, registration, token refresh,
patient message posting and ticket issue, and SHALL respond with HTTP 429 and a
`Retry-After` header when a limit is exceeded. The client address used for
limiting SHALL come from forwarding headers only when the request arrives from a
configured trusted proxy.

#### Scenario: Repeated failed logins are throttled

**Given** more than five login attempts for the same email within one minute
**When** another attempt arrives
**Then** the Core API responds 429 with `Retry-After`
**And** the credentials are not checked

#### Scenario: Spoofed forwarding headers do not evade limits

**Given** no trusted proxy is configured
**When** requests arrive with varying `X-Forwarded-For` values from one socket address
**Then** they share one rate-limit bucket
