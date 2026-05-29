# Specification: Vitals & Check-Ins

## ADDED Requirements

### Requirement: Server-Owned Check-In Schedule

The system SHALL own the check-in schedule for every enrolled patient on
the server side, with per-(patient, condition) cadence driven by the
condition's `titration_state`: weekly while `titrating`, monthly while
`maintenance`. The client SHALL NOT be trusted to compute or enforce the
schedule.

#### Scenario: A titrating patient receives a weekly cadence

- **GIVEN** a `patient_conditions` row with `titration_state = titrating`
- **WHEN** the scheduler computes the next due time
- **THEN** the next due time is seven days after the last
  responded-or-scheduled check-in for that (patient, condition) pair

#### Scenario: A maintenance patient receives a monthly cadence

- **GIVEN** a `patient_conditions` row with `titration_state = maintenance`
- **WHEN** the scheduler computes the next due time
- **THEN** the next due time is thirty days after the last
  responded-or-scheduled check-in for that (patient, condition) pair

#### Scenario: A client-side cadence override is ignored

- **GIVEN** a client request that includes a custom `next_due_at` value
- **WHEN** the scheduler processes the request
- **THEN** the client-supplied value is discarded
- **AND** the server-computed value is used

---

### Requirement: Check-In Delivery

When a check-in is due, the system SHALL create a new conversation thread
of type `check_in`, queue an APNs push to the patient referencing the
thread, and write a `check_in_responses` row in `pending` state. If the
patient does not respond within the next cadence cycle, the system SHALL
write an `audit_event` of type `check_in_missed`.

#### Scenario: A due check-in is delivered

- **GIVEN** a `check_in_schedules` row whose `next_due_at` is in the past
- **WHEN** the scheduler runs
- **THEN** a `conversations` row of type `check_in` is created
- **AND** an APNs push is queued for the patient
- **AND** a `check_in_responses` row is created with status `pending`

#### Scenario: A missed check-in is audited

- **GIVEN** a `check_in_responses` row in `pending` state whose creation
  is older than one cadence cycle
- **WHEN** the missed-check-in detector runs
- **THEN** an `audit_event` of type `check_in_missed` is written
- **AND** the patient's `check_in_schedules` row is re-queued

---

### Requirement: Vitals Capture In Check-Ins

A check-in conversation SHALL prompt the patient for the vitals relevant
to their enrolled conditions: blood pressure for `hypertension`, fasting
glucose and weight for `diabetes_t2`, weight only for `hyperlipidemia`.
Submitted vitals SHALL be written to `vitals_readings` and delivered to
the AI Agent Runtime as the message that closes the check-in thread.

#### Scenario: A hypertension check-in captures blood pressure

- **GIVEN** a patient enrolled in `hypertension` opens a due check-in
- **WHEN** they submit systolic and diastolic blood pressure values
- **THEN** two `vitals_readings` rows are written
  (`bp_systolic`, `bp_diastolic`)
- **AND** a message is posted to the check-in conversation summarising
  the submission
- **AND** the AI Agent Runtime processes the message against the
  patient's protocols

#### Scenario: A diabetes check-in captures fasting glucose and weight

- **GIVEN** a patient enrolled in `diabetes_t2` opens a due check-in
- **WHEN** they submit fasting glucose and weight values
- **THEN** two `vitals_readings` rows are written
  (`glucose_fasting`, `weight`)
- **AND** the AI Agent Runtime processes the resulting message

---

### Requirement: Titration-State Transition By Physician

A physician SHALL be able to move a (patient, condition) pair from
`titrating` to `maintenance` (and back) through a control on the
physician web app. The transition SHALL be audited and SHALL take effect
on the next scheduler tick.

#### Scenario: A physician moves a patient to maintenance

- **GIVEN** a `patient_conditions` row with `titration_state = titrating`
- **WHEN** the physician issues a state-transition action on the web app
- **THEN** the `titration_state` is set to `maintenance`
- **AND** an `audit_event` of type `titration_state_changed` is written
- **AND** the next check-in cadence reflects the new state
