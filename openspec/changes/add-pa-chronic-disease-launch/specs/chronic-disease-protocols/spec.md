# Specification: Chronic-Disease Protocols

## ADDED Requirements

### Requirement: Versioned Protocol Library

The system SHALL provide a protocol library with one package per Phase 1
condition (`diabetes_t2`, `hypertension`, `hyperlipidemia`). Each protocol
package SHALL export a pure function `Recommend(snapshot) []DraftRecommendation`
and a `ProtocolVersion` constant. Every recommendation produced by a
protocol SHALL be stamped with the protocol identifier and version on its
metadata field.

#### Scenario: Each Phase 1 condition has a protocol package

- **WHEN** the protocol registry is initialized
- **THEN** the registry contains protocol packages for `diabetes_t2`,
  `hypertension`, and `hyperlipidemia`
- **AND** each package exposes a `Recommend` function and a non-empty
  `ProtocolVersion`

#### Scenario: A draft is stamped with the producing protocol's version

- **GIVEN** a patient snapshot processed by the `diabetes_t2` protocol
  at version `2026.05.1`
- **WHEN** the protocol returns a draft recommendation
- **THEN** the resulting `Recommendation` row's metadata contains
  `protocol_id = diabetes_t2` and `protocol_version = 2026.05.1`

---

### Requirement: Phase 1 Formulary Constraint

Protocol-produced prescription drafts SHALL reference only medications in the Phase 1 formulary: metformin, an SGLT2 inhibitor, an ACE inhibitor or ARB, a statin, or a beta-blocker. Any draft prescription that references a medication outside this formulary SHALL be rejected at the recommendation-write boundary so that out-of-formulary drafts never reach the physician review queue.

#### Scenario: A formulary drug is allowed through

- **GIVEN** a protocol produces a prescription draft for `metformin`
- **WHEN** the recommendation-write boundary validates the draft
- **THEN** the draft is persisted as a `Recommendation` in `PENDING_REVIEW`

#### Scenario: A non-formulary drug is rejected

- **GIVEN** a protocol produces a prescription draft for a non-formulary
  medication (e.g., a GLP-1 agonist)
- **WHEN** the recommendation-write boundary validates the draft
- **THEN** the draft is rejected with a typed `ErrOutOfFormulary` error
- **AND** no `Recommendation` row is created
- **AND** an `ai_interaction_failed` audit event is written

---

### Requirement: Protocol Selection By Enrolled Condition

The AI Agent Runtime SHALL select protocols to run based on the patient's
`patient_conditions` rows. A patient enrolled in N conditions SHALL have
their snapshot processed by all N matching protocols plus the generic
guidance strategy. No protocol SHALL be run for a condition the patient
is not enrolled in.

#### Scenario: A two-condition patient triggers two protocols

- **GIVEN** a patient enrolled in `diabetes_t2` and `hypertension`
- **WHEN** the agent runtime processes a message or check-in from that
  patient
- **THEN** the `diabetes_t2` and `hypertension` protocols are run
- **AND** the `hyperlipidemia` protocol is not run

#### Scenario: A single-condition patient does not trigger other protocols

- **GIVEN** a patient enrolled only in `hyperlipidemia`
- **WHEN** the agent runtime processes a message from that patient
- **THEN** only the `hyperlipidemia` protocol is run
- **AND** neither `diabetes_t2` nor `hypertension` protocols are run

---

### Requirement: Drafts Land In PENDING_REVIEW Only

Protocol-produced drafts SHALL be persisted as `Recommendation` rows in
the `PENDING_REVIEW` state via the cloud-MVP physician-in-loop state
machine. No protocol code path SHALL bypass the state machine or move a
recommendation beyond `PENDING_REVIEW`.

#### Scenario: Every protocol-produced draft lands in PENDING_REVIEW

- **GIVEN** a protocol produces a draft of any payload type
- **WHEN** the draft is persisted
- **THEN** the resulting `Recommendation` row's state is `PENDING_REVIEW`
- **AND** the protocol code did not call any transition beyond
  `DRAFT → PENDING_REVIEW`
