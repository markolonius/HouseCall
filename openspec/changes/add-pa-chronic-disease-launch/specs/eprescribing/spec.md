# Specification: e-Prescribing Surface

## ADDED Requirements

### Requirement: Prescription As A Recommendation Payload Type

The system SHALL represent prescriptions as `Recommendation` rows with
`payload_type = prescription` and a structured payload containing: drug
(RxNorm code + display name), dose, sig, quantity, refills, pharmacy
(reference, name, phone), and a substitution-allowed flag. Prescriptions
SHALL flow through the same physician-in-loop state machine as every
other recommendation type.

#### Scenario: A prescription draft is persisted with a structured payload

- **GIVEN** a protocol produces a prescription draft for metformin
- **WHEN** the draft is persisted
- **THEN** a `Recommendation` row is created with
  `payload_type = prescription`
- **AND** the payload contains an RxNorm-coded drug, dose, sig,
  quantity, refills, and a pharmacy reference
- **AND** the row's state is `PENDING_REVIEW`

#### Scenario: A prescription cannot reach the patient before a physician signs it

- **GIVEN** a prescription `Recommendation` in `PENDING_REVIEW`
- **WHEN** the patient lists their visible recommendations
- **THEN** the prescription is not included
- **AND** the prescription's payload is not rendered anywhere in the
  patient app

---

### Requirement: Physician Prescribing UI With Sign-And-Approve

The physician web app SHALL provide a prescribing UI that lets the
reviewing physician edit drug, dose, sig, quantity, refills, and
pharmacy on a draft prescription before approving it. A "sign and
approve" action SHALL create a `prescription_transmissions` row in
`signed` status, transition the recommendation to `APPROVED` via the
state machine, and immediately deliver it to the patient.

#### Scenario: A physician signs and approves a prescription

- **GIVEN** a prescription `Recommendation` in `PENDING_REVIEW`
- **WHEN** the physician edits the sig, selects a pharmacy, and invokes
  "sign and approve"
- **THEN** the recommendation transitions `PENDING_REVIEW → MODIFIED →
  APPROVED → DELIVERED`
- **AND** a `prescription_transmissions` row is created with status
  `signed`
- **AND** an audit event records the signing
- **AND** the patient sees the prescription action card

#### Scenario: A physician cannot sign without selecting a pharmacy

- **GIVEN** a prescription `Recommendation` whose payload has no
  pharmacy reference
- **WHEN** the physician invokes "sign and approve" without selecting
  one
- **THEN** the action is rejected with a typed validation error
- **AND** no state transition occurs
- **AND** no `prescription_transmissions` row is created

---

### Requirement: Patient-Facing Prescription Action Card

A delivered prescription SHALL render in the patient app as an action
card containing drug, dose, sig, pharmacy name and phone. The card SHALL
NOT display internal identifiers, RxNorm codes, or transmission status
details intended for the prescribing surface.

#### Scenario: A patient sees their prescription

- **GIVEN** a `DELIVERED` prescription `Recommendation` for a patient
- **WHEN** the patient opens the conversation containing it
- **THEN** an action card renders showing the drug display name, dose,
  sig, and pharmacy name and phone
- **AND** RxNorm codes and internal identifiers are not displayed

---

### Requirement: Transmission Status Tracking

The system SHALL track prescription transmission status on a
`prescription_transmissions` table keyed by recommendation id. In Phase 1
the table SHALL support the statuses (`drafted`, `signed`, `transmitted`,
`failed`). Phase 1 writes only `drafted` and `signed`; `transmitted` and
`failed` writes are reserved for a future change that integrates with
Surescripts or equivalent.

#### Scenario: A signed prescription remains in signed status in Phase 1

- **GIVEN** a prescription that has been signed by the physician
- **WHEN** Phase 1 code paths complete
- **THEN** the `prescription_transmissions` row's status is `signed`
- **AND** no Phase 1 code path writes `transmitted` or `failed`
