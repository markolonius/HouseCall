# core-api — Agent Care Loop Deltas

## ADDED Requirements

### Requirement: Conversation Care Phase Exposure

The Core API SHALL persist each conversation's care phase (`INTAKE`,
`AWAITING_REVIEW`, `PLAN_DELIVERED`) and SHALL include it in conversation
resources returned to authenticated clients. Existing conversations SHALL be
backfilled from their recommendation history: `PLAN_DELIVERED` when a
delivered recommendation exists, `AWAITING_REVIEW` when a pending one exists,
otherwise `INTAKE`.

#### Scenario: Conversation resources carry the care phase

**Given** an authenticated patient with a conversation in `AWAITING_REVIEW`
**When** the patient's client fetches that conversation
**Then** the response includes the care phase `AWAITING_REVIEW`

#### Scenario: Pre-existing conversations are backfilled

**Given** a conversation created before care phases existed that has a
delivered recommendation
**When** the backfill migration runs
**Then** that conversation's care phase is `PLAN_DELIVERED`
