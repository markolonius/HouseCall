# physician-web-app (delta)

## ADDED Requirements

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
