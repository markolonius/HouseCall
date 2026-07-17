# physician-web-app — Agent Care Loop Deltas

## MODIFIED Requirements

### Requirement: Review Actions

The physician web app SHALL let the physician approve, reject, or modify a
`PENDING_REVIEW` recommendation. Each action SHALL invoke the corresponding
Core API state transition. `modify` SHALL allow editing the content before
delivery. `reject` SHALL require a non-empty reason, submitted with the
transition.

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

#### Scenario: Reject requires a reason and is never delivered

**Given** a `PENDING_REVIEW` recommendation in the physician's queue
**When** the physician rejects it with a reason
**Then** the recommendation transitions to `REJECTED` with that reason stored
**And** the patient never receives its content

#### Scenario: Reject without a reason is blocked in the UI

**Given** a `PENDING_REVIEW` recommendation in the physician's queue
**When** the physician submits a rejection with an empty reason field
**Then** the rejection is not submitted and the physician is prompted for a
reason
