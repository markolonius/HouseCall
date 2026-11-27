# ai-chat-interface (delta)

## ADDED Requirements

### Requirement: Trust Controls in Profile

The Profile screen SHALL give the patient access to their access history, a
download of their records, and account closure. Account closure SHALL explain
that medical records are retained for the legally required period before the
patient confirms. All three SHALL be usable with VoiceOver and Dynamic Type.

#### Scenario: The patient views access history

**Given** a signed-in patient on the Profile screen
**When** they open Access history
**Then** a list of access events is shown, newest first, with who and when

#### Scenario: The patient downloads their records

**Given** a signed-in patient on the Profile screen
**When** they choose Download my records
**Then** the export is fetched and the share sheet opens with the file
**And** the temporary file is removed after the share sheet closes

#### Scenario: Closing the account explains retention first

**Given** a signed-in patient on the Profile screen
**When** they choose Close account
**Then** the app explains that records are retained for the legal period before deletion
**And** the account is closed only after they confirm with their password
**And** the app signs out and clears local data
