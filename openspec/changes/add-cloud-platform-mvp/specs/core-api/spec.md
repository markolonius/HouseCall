# Specification: Core API

## ADDED Requirements

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
