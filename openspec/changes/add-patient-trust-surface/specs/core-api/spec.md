# core-api (delta)

## ADDED Requirements

### Requirement: Recommendation Reviewer Attribution

The Core API SHALL include, with every delivered recommendation returned to a
patient, the reviewing physician's name, credential and the licence state under
which they acted, the review time, and whether the physician edited the draft.
It SHALL NOT include the AI-drafted text of a recommendation the physician
modified.

#### Scenario: A delivered recommendation identifies its reviewer

**Given** a recommendation approved by a physician licensed in the patient's state
**When** the patient fetches the recommendation
**Then** the response includes the physician's name, credential, the licence state, and the review time

#### Scenario: An edited recommendation is flagged without the draft

**Given** a recommendation the physician modified before delivery
**When** the patient fetches it
**Then** the response indicates it was edited
**And** the response contains only the physician-approved content, not the AI draft

### Requirement: Patient Access Log

The Core API SHALL let a patient list, newest first and paginated, the access
events on their own records: when, who (a named physician, the HouseCall
assistant, or the patient), and a short description of the action. Entries
SHALL contain no record content and SHALL never include another patient's
events.

#### Scenario: A physician's review appears in the log

**Given** a physician reviewed one of the patient's recommendations
**When** the patient requests their access log
**Then** an entry shows the physician's name, the time, and that a recommendation was reviewed

#### Scenario: Another patient's events are never shown

**Given** audit events exist for a different patient in the same tenant
**When** the patient requests their access log
**Then** none of those events appear

### Requirement: Patient Data Export

The Core API SHALL let a patient download, as a single JSON document, their
profile, conversations and messages, delivered recommendations with reviewer
attribution, and access log. Each export SHALL be audited and rate-limited.

#### Scenario: A patient exports their records

**Given** an authenticated patient
**When** the patient requests an export
**Then** the response contains their profile, conversations, messages and delivered recommendations
**And** a `records_exported` audit event is written

### Requirement: Account Closure

The Core API SHALL let a patient close their account after confirming their
password. Closure SHALL immediately disable sign-in and revoke all of the
patient's refresh tokens, and SHALL retain the patient's clinical records for
the configured legal retention period before deletion.

#### Scenario: A closed account cannot sign in

**Given** a patient who has closed their account
**When** they attempt to sign in
**Then** sign-in fails
**And** previously issued refresh tokens are rejected

#### Scenario: Records are retained after closure

**Given** a patient closed their account less than the retention period ago
**When** the records are inspected by an authorised administrator
**Then** the patient's messages and recommendations still exist
