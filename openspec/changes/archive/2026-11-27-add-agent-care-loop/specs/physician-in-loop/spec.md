# physician-in-loop — Agent Care Loop Deltas

## ADDED Requirements

### Requirement: Rejection Reason Capture

A physician rejection SHALL require a non-empty reason. The reason SHALL be
stored on the rejected recommendation and included in the transition's audit
event, in the same transaction as the state change. The reason SHALL never be
delivered to the patient. The recommendation lifecycle is unchanged:
`REJECTED` remains terminal for the rejected row; any revision is a new
recommendation.

#### Scenario: Rejecting without a reason is refused

**Given** a recommendation in `PENDING_REVIEW`
**When** a physician submits a rejection with an empty reason
**Then** the transition is rejected with an error
**And** the recommendation remains in `PENDING_REVIEW`

#### Scenario: The reason is stored and audited atomically

**Given** a recommendation in `PENDING_REVIEW`
**When** a physician rejects it with reason "ask about current medications"
**Then** the recommendation moves to `REJECTED` with that reason stored
**And** the audit event for the transition records the reason in the same
transaction

#### Scenario: The rejected row stays terminal

**Given** a recommendation in `REJECTED` with a stored reason
**When** any further transition on that recommendation is attempted
**Then** the transition is rejected with an error
