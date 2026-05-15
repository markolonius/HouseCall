# Specification: Physician Web App

## ADDED Requirements

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
