# core-api Specification

## Purpose
TBD - created by archiving change add-cloud-platform-mvp. Update Purpose after archive.
## Requirements
### Requirement: Tenant-Scoped Data Model

The Core API SHALL persist every PHI-bearing record with a `tenant_id`, and
every read or write path SHALL be scoped to a single tenant. No API or store
operation SHALL expose a cross-tenant read path.

#### Scenario: Query is scoped to the caller's tenant

**Given** a patient belonging to tenant A and a patient belonging to tenant B
**When** the Core API serves a request authenticated as tenant A
**Then** only tenant A's records are returned
**And** tenant B's records are not reachable through any parameter

#### Scenario: Cross-tenant access is rejected

**Given** a record that belongs to tenant B
**When** a request authenticated as tenant A asks for that record by id
**Then** the Core API responds as if the record does not exist
**And** an audit event records the denied access

---

### Requirement: Authenticated API Access

The Core API SHALL require a valid signed JWT on every `/api` request and on the
WebSocket connection. The token SHALL carry the caller's `tenant_id` and actor
identity, and middleware SHALL reject any missing, malformed, or expired token.

#### Scenario: Missing or invalid token is rejected

**Given** a request to a Core API endpoint
**When** the request has no token, a malformed token, or an expired token
**Then** the Core API responds with an unauthorized status
**And** no handler logic runs

#### Scenario: Valid token establishes tenant and actor context

**Given** a request with a valid JWT for a patient in tenant A
**When** the request reaches a handler
**Then** the handler operates with `tenant_id` A and that patient's identity
**And** the caller cannot act outside that tenant or identity

---

### Requirement: Patient Message Ingestion

The Core API SHALL accept a patient message on a conversation, persist it
tenant-scoped, and trigger the AI Agent Runtime. The patient SHALL NOT receive
any AI-generated content directly from this endpoint.

#### Scenario: A patient message is persisted and triggers the agent

**Given** an authenticated patient with a conversation
**When** the patient sends a message to that conversation
**Then** the message is persisted with the patient's `tenant_id`
**And** an audit event for the message is written
**And** the AI Agent Runtime is invoked for that conversation
**And** the response to the patient contains no AI-generated content

---

### Requirement: WebSocket Live Updates

The Core API SHALL provide a WebSocket channel that pushes
`recommendation.delivered` events to the relevant patient and `queue.updated`
events to the relevant physician. Events SHALL be tenant-scoped and SHALL NOT
deliver a recommendation's content before it reaches the `DELIVERED` state.

#### Scenario: A delivered recommendation notifies the patient

**Given** a patient connected to the WebSocket
**When** one of that patient's recommendations transitions to `DELIVERED`
**Then** the patient receives a `recommendation.delivered` event
**And** the patient does not receive events for any other tenant

---

### Requirement: Audit Logging

The Core API SHALL write an append-only `AuditEvent` for every operation that
touches PHI — message ingestion, agent interaction, and every recommendation
state transition. Audit events SHALL contain metadata and identifiers only, never
PHI content.

#### Scenario: A PHI-touching operation produces an audit event

**Given** any operation that creates or transitions a PHI record
**When** the operation completes
**Then** an `AuditEvent` is written with the event type, actor id, and tenant
**And** the audit event contains no message or recommendation content

---

### Requirement: Typed Recommendation Payload

Every Recommendation SHALL carry a `payload_type` discriminator drawn from the
set `guidance`, `prescription`, `lab_order`, `referral`, and a `payload` value
matching that type's shape. The MVP agent SHALL only produce `guidance`
payloads; the other types SHALL be valid persistable values so the prescribing
slice can introduce them without a schema migration.

#### Scenario: A drafted recommendation carries a typed guidance payload

**Given** a patient message that the agent has processed
**When** the resulting Recommendation is persisted
**Then** its `payload_type` is `guidance`
**And** its `payload` contains the model-generated text for that type

#### Scenario: Unknown payload types are rejected

**Given** a write to the recommendations table
**When** the `payload_type` is not one of the four defined values
**Then** the write is rejected by the database constraint
**And** no recommendation is created

---

### Requirement: No PHI Monetization Surface

The Core API SHALL NOT expose any endpoint, event stream, or export path whose
purpose is marketing analytics, advertising attribution, or third-party data
sharing for PHI. Read access to PHI SHALL be limited to the patient who owns
it, physicians with an active care relationship to that patient within the
tenant, and the patient's own audit history.

#### Scenario: No third-party PHI export endpoint exists

**Given** the published Core API surface
**When** the surface is enumerated
**Then** no endpoint serves PHI to a third-party identifier such as an
advertising or analytics audience
**And** the only PHI-bearing reads are scoped to the owning patient or a
care-related physician within the tenant

### Requirement: Patient Registration

The Core API SHALL provide a registration endpoint that creates a tenant-scoped
patient from an email and password, storing the password as a bcrypt hash, and
SHALL return an authentication token so the client is immediately authenticated.
Registration SHALL reject a duplicate email within the same tenant and SHALL
write an audit event containing identifiers only.

#### Scenario: New patient registers

- **GIVEN** a valid tenant and an email not yet registered in that tenant
- **WHEN** the client POSTs the email and password to the registration endpoint
- **THEN** a patient record is created in that tenant with a bcrypt password hash
- **AND** an authentication token is returned
- **AND** a `patient.registered` audit event is written with identifiers only (no password, no PHI)

#### Scenario: Duplicate email is rejected

- **GIVEN** an email already registered within the tenant
- **WHEN** the client attempts to register that email again
- **THEN** the request is rejected as a conflict
- **AND** no second patient record is created

#### Scenario: Missing fields are rejected

- **GIVEN** a registration request missing tenant, email, or password
- **WHEN** the request is processed
- **THEN** it is rejected as a bad request
- **AND** no patient record is created

#### Scenario: Returned token authenticates API access

- **GIVEN** a successful registration
- **WHEN** the returned token is used as a Bearer token on an authenticated `/api/*` request
- **THEN** the request is accepted as that patient within the tenant

### Requirement: Agent Interview Message Delivery

The Core API SHALL provide a channel for the AI Agent Runtime to deliver a
non-clinical interview question to the originating patient: the question SHALL be
persisted as an assistant message on the conversation and pushed to the patient's
live WebSocket connection when present. Interview questions SHALL NOT pass through
the recommendation review lifecycle.

#### Scenario: Interview question reaches the patient

- **GIVEN** the agent runtime generates an interview question for a conversation
- **WHEN** the Core API delivers it
- **THEN** the question is persisted as an assistant message on that conversation
- **AND** it is pushed to the patient's WebSocket if connected
- **AND** no recommendation row is created for the question

#### Scenario: Offline patient receives the question on reconnect

- **GIVEN** the patient is offline when an interview question is delivered
- **WHEN** the patient reconnects and syncs the conversation
- **THEN** the persisted assistant message is included in the message history

### Requirement: SOAP Note Recommendation Payload

The Core API SHALL accept and persist Recommendations with `payload_type` =
`soap_note` whose payload contains structured Subjective, Objective, Assessment,
and Plan fields, scoped to the owning tenant like every other recommendation.

#### Scenario: A soap_note recommendation is tenant-scoped

- **GIVEN** a `soap_note` recommendation drafted for a patient in tenant A
- **WHEN** it is persisted and later queried
- **THEN** it is only ever returned within tenant A's scope
- **AND** its payload exposes the Subjective, Objective, Assessment, and Plan fields

### Requirement: Conversation Care Phase Exposure

The Core API SHALL persist each conversation's care phase (`INTAKE`,
`AWAITING_REVIEW`, `PLAN_DELIVERED`) and SHALL include it in conversation
resources returned to authenticated clients. Existing conversations SHALL be
backfilled from their recommendation history: `PLAN_DELIVERED` when a
delivered recommendation exists, `AWAITING_REVIEW` when a pending one exists,
otherwise `INTAKE`.

#### Scenario: Conversation resources carry the care phase

**Given** an authenticated patient with a conversation in `AWAITING_REVIEW`
**When** the patient's client fetches that conversation
**Then** the response includes the care phase `AWAITING_REVIEW`

#### Scenario: Pre-existing conversations are backfilled

**Given** a conversation created before care phases existed that has a
delivered recommendation
**When** the backfill migration runs
**Then** that conversation's care phase is `PLAN_DELIVERED`

