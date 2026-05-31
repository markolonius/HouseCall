# Specification: AI Agent Runtime

## ADDED Requirements

### Requirement: Reactive Recommendation Drafting

When a patient message is persisted, the AI Agent Runtime SHALL assemble the
tenant-scoped conversation context, call the configured model, and produce a
Recommendation in the `PENDING_REVIEW` state. The runtime SHALL act only in
response to a patient message in the MVP — no proactive or scheduled behaviour.

#### Scenario: A patient message produces a pending recommendation

**Given** a persisted patient message on a conversation
**When** the AI Agent Runtime processes it
**Then** it assembles context from that conversation's messages only
**And** it produces a Recommendation in `PENDING_REVIEW`
**And** a `queue.updated` event is emitted for the supervising physician

---

### Requirement: Local Model Endpoint Integration

The AI Agent Runtime SHALL call a configurable OpenAI-compatible model endpoint.
The endpoint URL SHALL be configuration-driven so the same code path serves a
local development model and, later, a production-hosted model.

#### Scenario: The runtime calls the configured endpoint

**Given** a configured OpenAI-compatible model endpoint
**When** the AI Agent Runtime drafts a recommendation
**Then** it sends the assembled context to that endpoint
**And** it uses the model's response as the recommendation's draft content

#### Scenario: The model endpoint is unavailable

**Given** the configured model endpoint is unreachable or returns an error
**When** the AI Agent Runtime attempts to draft a recommendation
**Then** no Recommendation is created
**And** an `ai_interaction_failed` audit event is written
**And** no error content is presented to the patient as a clinical response

---

### Requirement: The Agent Cannot Deliver

The AI Agent Runtime SHALL only ever create a Recommendation in `DRAFT` and move
it to `PENDING_REVIEW`. It SHALL have no code path that transitions a
Recommendation to `APPROVED`, `MODIFIED`, or `DELIVERED`.

#### Scenario: Agent output always lands in PENDING_REVIEW

**Given** the AI Agent Runtime has drafted a recommendation
**When** the draft is complete
**Then** the recommendation is in `PENDING_REVIEW`
**And** the runtime has not transitioned it any further

---

### Requirement: Guidance Payload Only In MVP

The AI Agent Runtime SHALL produce Recommendations with `payload_type` =
`guidance` and SHALL NOT produce `prescription`, `lab_order`, or `referral`
payloads in this slice. The runtime SHALL be structured so that additional
payload types can be added as new agent strategies without changing the
review lifecycle.

#### Scenario: A drafted recommendation is a guidance payload

**Given** the AI Agent Runtime has drafted a recommendation
**When** the draft is persisted
**Then** the recommendation's `payload_type` is `guidance`
**And** the runtime does not write any other `payload_type`
