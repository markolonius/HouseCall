# physician-web-app Specification

## Purpose
TBD - created by archiving change add-cloud-platform-mvp. Update Purpose after archive.
## Requirements
### Requirement: Physician Authentication

The physician web app SHALL require a physician to authenticate before any
patient data or recommendation is shown. An unauthenticated request SHALL be
redirected to the login form.

#### Scenario: Unauthenticated access is redirected

**Given** an unauthenticated browser session
**When** the session requests the panel or the review queue
**Then** the request is redirected to the login form
**And** no patient data is rendered

#### Scenario: A physician logs in

**Given** a physician with valid credentials
**When** the physician submits the login form
**Then** a session is established that carries the physician's identity and tenant

---

### Requirement: Recommendation Review Queue

The physician web app SHALL show a queue of `PENDING_REVIEW` recommendations
limited to patients the signed-in physician has an active care relationship
with, within the physician's tenant.

#### Scenario: The queue shows only the physician's patients

**Given** a physician with active care relationships for some patients
**When** the physician opens the review queue
**Then** only `PENDING_REVIEW` recommendations for those patients are listed
**And** recommendations for other physicians' patients are not listed
**And** recommendations from other tenants are not listed

---

### Requirement: Review Actions

The physician web app SHALL let the physician approve, reject, or modify a
`PENDING_REVIEW` recommendation. Each action SHALL invoke the corresponding
Core API state transition. `modify` SHALL allow editing the content before
delivery.

#### Scenario: Approve delivers the recommendation

**Given** a `PENDING_REVIEW` recommendation in the physician's queue
**When** the physician approves it
**Then** the recommendation transitions to `APPROVED` and then `DELIVERED`
**And** the patient receives the recommendation's content

#### Scenario: Modify edits content before delivery

**Given** a `PENDING_REVIEW` recommendation in the physician's queue
**When** the physician edits its content and submits the modification
**Then** the recommendation transitions to `MODIFIED` and then `DELIVERED`
**And** the patient receives the edited content

#### Scenario: Reject is terminal and never delivered

**Given** a `PENDING_REVIEW` recommendation in the physician's queue
**When** the physician rejects it
**Then** the recommendation transitions to `REJECTED`
**And** the patient never receives its content

### Requirement: SOAP Note Review Rendering

The physician web app SHALL render a `soap_note` recommendation in the review
queue with its Subjective, Objective, Assessment, and Plan sections clearly
delineated, presenting the Assessment and Plan as the physician's decision focus.

#### Scenario: Physician opens a SOAP note for review

- **GIVEN** a `soap_note` recommendation in `PENDING_REVIEW`
- **WHEN** the physician opens it in the review queue
- **THEN** the Subjective, Objective, Assessment, and Plan sections are displayed
- **AND** the Assessment and Plan are presented as editable decision content

### Requirement: SOAP Note Approval Actions

The physician web app SHALL allow a state-licensed physician to approve, modify
(edit the Assessment and/or Plan), or reject a `soap_note` recommendation, using
the existing recommendation review actions and state-licensing checks.

#### Scenario: Physician approves a SOAP note unchanged

- **GIVEN** a `soap_note` in `PENDING_REVIEW` and a physician licensed in the
  patient's state
- **WHEN** the physician approves it
- **THEN** the recommendation transitions to `APPROVED`

#### Scenario: Physician edits the plan before approving

- **GIVEN** a `soap_note` in `PENDING_REVIEW`
- **WHEN** the physician edits the Plan and saves
- **THEN** the recommendation transitions to `MODIFIED` with the edited content

#### Scenario: Unlicensed physician cannot act

- **GIVEN** a `soap_note` for a patient in a state the physician is not licensed in
- **WHEN** the physician attempts to approve, modify, or reject it
- **THEN** the action is refused

