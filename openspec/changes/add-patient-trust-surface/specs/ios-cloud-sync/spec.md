# ios-cloud-sync (delta)

## MODIFIED Requirements

### Requirement: Inline Recommendation Card Rendering

The iOS app SHALL render a delivered Recommendation as an inline action card
within the chat conversation, keyed off the recommendation's `payload_type`.
The MVP SHALL implement a single `guidance` card type that displays the
delivered text; the renderer SHALL be structured so that future
`prescription`, `lab_order`, and `referral` card types can be added without
restructuring the chat surface. Every card for a delivered recommendation SHALL
show the reviewing physician's name, credential and licence state, and SHALL
indicate when the physician edited the draft.

#### Scenario: A guidance recommendation renders as an inline card

**Given** a recommendation has been delivered with `payload_type = guidance`
**When** the iOS app displays it in the conversation
**Then** the recommendation appears as an inline `RecommendationCard` of the
guidance variant showing the delivered text
**And** it does not appear as a plain assistant chat bubble

#### Scenario: Unknown payload types degrade safely

**Given** a recommendation arrives with a `payload_type` the app does not yet
render (e.g. `prescription` before differentiated cards ship)
**When** the iOS app displays it in the conversation
**Then** it renders the recommendation's textual content as a generic card
**And** the app does not crash or silently drop the recommendation

#### Scenario: The card names its reviewer

**Given** a delivered recommendation with reviewer attribution
**When** the card is displayed
**Then** it shows "Reviewed by Dr." followed by the physician's name, credential and licence state

#### Scenario: An edited recommendation is marked

**Given** a delivered recommendation that the physician edited
**When** the card is displayed
**Then** it shows that the recommendation was edited by the patient's physician

#### Scenario: Recommendations without attribution still render

**Given** a delivered recommendation from before attribution existed
**When** the card is displayed
**Then** it renders the delivered text without a reviewer line
