# Specification: Patient Intake

## ADDED Requirements

### Requirement: State-Of-Residence Eligibility Gate

The system SHALL block any patient signup whose declared state of residence
is not in the hardcoded eligible-state allowlist. In Phase 1 the allowlist
is `{PA}`. The block SHALL occur before any clinical data is collected and
before any payment surface is shown.

#### Scenario: A PA resident proceeds to intake

- **GIVEN** a prospective patient declares state of residence `PA`
- **WHEN** they submit the eligibility-check step
- **THEN** the system returns an eligible response
- **AND** the patient may proceed to the demographics and condition-selection
  steps

#### Scenario: A non-PA resident is blocked at the eligibility gate

- **GIVEN** a prospective patient declares state of residence `NJ`
- **WHEN** they submit the eligibility-check step
- **THEN** the system returns an ineligible response with a waitlist token
- **AND** the patient is routed to a "not available in your state yet"
  screen
- **AND** no `patients` row, `intake_submissions` row, or `subscriptions`
  row is created

#### Scenario: A patient cannot bypass the gate by skipping the check

- **GIVEN** a prospective patient attempts to submit an intake payload
  directly
- **WHEN** the intake-submit endpoint receives a request whose patient
  state is not in the eligible-state allowlist
- **THEN** the request is rejected with a typed `ErrStateNotEligible`
- **AND** no row is written to any intake or patient table

---

### Requirement: Chronic-Disease Condition Selection

The intake flow SHALL require the patient to select one or more chronic
conditions from the Phase 1 enrolled-condition set: `diabetes_t2`,
`hypertension`, `hyperlipidemia`. The selection SHALL be persisted on the
`patient_conditions` table and used downstream by the protocol library and
the subscription-tier mapper.

#### Scenario: A patient enrolls in a single condition

- **GIVEN** an eligible PA-resident patient completing intake
- **WHEN** they select `hypertension` as their only condition
- **THEN** a `patient_conditions` row is created with
  `condition = hypertension` and `titration_state = titrating`
- **AND** the downstream tier mapper returns the one-condition tier

#### Scenario: A patient enrolls in multiple conditions

- **GIVEN** an eligible PA-resident patient completing intake
- **WHEN** they select `diabetes_t2` and `hyperlipidemia`
- **THEN** two `patient_conditions` rows are created, one per condition
- **AND** the downstream tier mapper returns the two-condition tier

#### Scenario: A patient cannot select a non-Phase-1 condition

- **GIVEN** an intake submission that includes a condition not in the
  Phase 1 set (e.g., `weight_management`)
- **WHEN** the intake-submit endpoint validates the payload
- **THEN** the request is rejected with a typed validation error
- **AND** no `patient_conditions` row is created

---

### Requirement: Baseline Clinical Data Capture

The intake flow SHALL capture baseline vitals (most recent blood pressure,
fasting glucose where relevant, weight, height), current medications,
allergies, and most-recent lab results (HbA1c, lipid panel, basic metabolic
panel where available). Captured data SHALL be encrypted at rest in
`intake_submissions` and SHALL be available to the AI Agent Runtime as
context for the patient's first protocol-driven recommendation.

#### Scenario: A complete intake submission is persisted encrypted

- **GIVEN** a patient submits a complete intake payload
- **WHEN** the intake-submit endpoint processes the payload
- **THEN** an `intake_submissions` row is written with the payload
  encrypted under the tenant's encryption envelope
- **AND** an `audit_event` is written with metadata only (no PHI)

#### Scenario: A partial intake submission is rejected with field-level errors

- **GIVEN** a patient submits intake without a required baseline-vital
  field for one of their selected conditions (e.g., no blood pressure when
  `hypertension` is selected)
- **WHEN** the intake-submit endpoint validates the payload
- **THEN** the request is rejected with field-level validation errors
- **AND** no `intake_submissions` row is created

---

### Requirement: Non-PA Waitlist Capture

The system SHALL offer non-eligible prospective patients a waitlist signup
that captures email and declared state only. No PHI SHALL be collected on
the waitlist path.

#### Scenario: A non-PA prospect joins the waitlist

- **GIVEN** a non-PA prospective patient on the "not available in your
  state yet" screen
- **WHEN** they submit their email address
- **THEN** a `waitlist_signups` row is created with `email`, `state`,
  `created_at` only
- **AND** no other patient or clinical row is created

#### Scenario: Waitlist signup rejects clinical fields

- **GIVEN** a waitlist-submit request that includes condition, vitals, or
  any other clinical field
- **WHEN** the waitlist endpoint validates the payload
- **THEN** the clinical fields are rejected and not persisted anywhere
