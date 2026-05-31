# Specification: Pennsylvania Clinical Compliance

## ADDED Requirements

### Requirement: Clinical-Entity Stamp On Every Clinical Record

Every PHI-bearing clinical record SHALL carry a non-null `clinical_entity_id` referencing the `clinical_entities` table. The covered records include `recommendations`, `conversations`, `vitals_readings`, `intake_submissions`, `check_in_responses`, `prescription_transmissions`, `lab_order_fulfillments`, and `audit_events`. In Phase 1 the `clinical_entities` table contains a single row representing the PA-PC. The stamp MUST be set by middleware derived from the patient's resident state and MUST NOT be settable by a handler.

#### Scenario: Every clinical write carries a clinical-entity stamp

- **GIVEN** any clinical-record write path in the backend
- **WHEN** a row is written
- **THEN** the row's `clinical_entity_id` is non-null and references an
  existing `clinical_entities` row
- **AND** the value was set by the entity-stamp middleware, not by the
  handler

#### Scenario: A test asserts no clinical record can be written without a stamp

- **GIVEN** the full test suite
- **WHEN** the per-handler clinical-write tests run
- **THEN** each test asserts the resulting row has a non-null
  `clinical_entity_id`
- **AND** any handler that bypasses the middleware fails the suite

---

### Requirement: Physician License Verification

The system SHALL maintain a `physician_license_status` record per
prescribing physician containing the verified license number, the
verifying source, the verified status (one of `active`,
`probation`, `disciplinary_action`, `expired`, `unknown`), the
verification timestamp, and the expiration date. The record SHALL be
refreshed by a daily scheduled job. Stale records (older than 30 days) or
records whose status is not `active` SHALL gate every physician-side
state-machine transition.

#### Scenario: An active license allows physician actions

- **GIVEN** a `physician_license_status` row with `status = active` and
  verified within the last 30 days
- **WHEN** the physician approves, modifies, or rejects a recommendation
- **THEN** the action proceeds

#### Scenario: A stale license blocks physician actions

- **GIVEN** a `physician_license_status` row last verified more than 30
  days ago
- **WHEN** the physician attempts to approve, modify, or reject a
  recommendation
- **THEN** the action is rejected with a typed `ErrLicenseStale` error
- **AND** the rejection is audited
- **AND** no state-machine transition occurs

#### Scenario: A non-active status blocks physician actions

- **GIVEN** a `physician_license_status` row with
  `status IN ('probation', 'disciplinary_action', 'expired', 'unknown')`
- **WHEN** the physician attempts to approve, modify, or reject a
  recommendation
- **THEN** the action is rejected with a typed `ErrLicenseNotActive` error
- **AND** the rejection is audited
- **AND** no state-machine transition occurs

#### Scenario: The physician web app surfaces license status

- **GIVEN** the physician opens the web app
- **WHEN** the status bar renders
- **THEN** the verified-through date and current status are displayed
- **AND** review actions are disabled when the status is stale or
  non-active

---

### Requirement: PDMP Acknowledgment On Controlled-Substance Prescriptions

The system SHALL require the prescribing physician to acknowledge a PA
Prescription Drug Monitoring Program (PDMP) lookup inline with every
controlled-substance prescription. The acknowledgment SHALL be persisted
as a `pdmp_acknowledgments` row containing the prescribing physician id,
the patient id, the medication class, the acknowledgment timestamp, and a
reference to the lookup result (free-text in Phase 1). A controlled-
substance prescription SHALL NOT be signed without a matching
acknowledgment.

#### Scenario: A controlled-substance prescription requires PDMP
acknowledgment

- **GIVEN** a prescription draft whose drug is in a controlled-substance
  class
- **WHEN** the physician invokes "sign and approve"
- **THEN** the prescribing UI requires a PDMP acknowledgment before the
  signing proceeds
- **AND** completing the acknowledgment writes a
  `pdmp_acknowledgments` row
- **AND** only then does the prescription transition to `APPROVED`

#### Scenario: A non-controlled prescription does not require PDMP
acknowledgment

- **GIVEN** a prescription draft for a Phase 1 formulary medication
  (none of which are controlled substances)
- **WHEN** the physician invokes "sign and approve"
- **THEN** the signing proceeds without a PDMP acknowledgment prompt
- **AND** no `pdmp_acknowledgments` row is created

#### Scenario: The PDMP surface is exercised by a debug-mode test

- **GIVEN** a test that promotes a fake controlled-class medication
  through the prescribing flow
- **WHEN** the test runs against the prescribing UI
- **THEN** the PDMP acknowledgment is required
- **AND** a `pdmp_acknowledgments` row is written on completion
