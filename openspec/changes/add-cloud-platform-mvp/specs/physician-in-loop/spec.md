# Specification: Physician-in-Loop

## ADDED Requirements

### Requirement: Recommendation Lifecycle State Machine

A Recommendation SHALL move only through the defined states: `DRAFT` →
`PENDING_REVIEW` → (`APPROVED` | `MODIFIED` | `REJECTED`), and `APPROVED` or
`MODIFIED` → `DELIVERED`. `REJECTED` SHALL be terminal. Any transition not in
this set SHALL be rejected with an error and SHALL NOT change state.

#### Scenario: A valid transition succeeds

**Given** a recommendation in `PENDING_REVIEW`
**When** a physician approves it
**Then** the recommendation moves to `APPROVED`
**And** it may then transition to `DELIVERED`

#### Scenario: An invalid transition is rejected

**Given** a recommendation in `PENDING_REVIEW`
**When** a transition directly to `DELIVERED` is attempted
**Then** the transition is rejected with an error
**And** the recommendation remains in `PENDING_REVIEW`

#### Scenario: Rejected is terminal

**Given** a recommendation in `REJECTED`
**When** any further transition is attempted
**Then** the transition is rejected with an error

---

### Requirement: No Patient Delivery Without a Physician Transition

A Recommendation's content SHALL become visible to a patient only through the
`DELIVERED` state, and `DELIVERED` SHALL be reachable only from `APPROVED` or
`MODIFIED` — both of which require a physician action. No AI-generated content
SHALL reach a patient without a physician state transition.

#### Scenario: A pending recommendation is not patient-visible

**Given** a recommendation in `PENDING_REVIEW`
**When** the patient requests that recommendation
**Then** its content is not returned to the patient

#### Scenario: A rejected recommendation is never delivered

**Given** a recommendation that a physician has moved to `REJECTED`
**When** any delivery is attempted
**Then** the recommendation is not delivered
**And** its content never becomes patient-visible

#### Scenario: Only a physician action reaches the patient

**Given** a recommendation drafted by the AI Agent Runtime
**When** no physician has acted on it
**Then** the patient has received no content from it
**And** content reaches the patient only after a physician approves or modifies it

---

### Requirement: Audited State Transitions

Every Recommendation state transition SHALL record the acting party, the action
taken, and a timestamp, written in the same database transaction as the state
change so a transition can never occur without its audit record.

#### Scenario: A transition writes its audit record atomically

**Given** a recommendation undergoing a state transition
**When** the transition is committed
**Then** an audit event with the actor, action, and timestamp is committed in
the same transaction
**And** if the audit write fails, the state change is rolled back
