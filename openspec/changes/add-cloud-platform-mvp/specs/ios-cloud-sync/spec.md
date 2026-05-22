# Specification: iOS Cloud Sync

## ADDED Requirements

### Requirement: Server-Backed Message Sync

The iOS app SHALL send patient messages to the Core API rather than calling an
LLM provider directly. Each local `Conversation` and `Message` SHALL carry a
`serverId` and a `syncState` (`local`, `pending`, `synced`, `failed`), and a
locally created message SHALL be marked `pending` until the Core API confirms it.

#### Scenario: A sent message syncs to the Core API

**Given** an authenticated patient composing a message
**When** the patient sends the message
**Then** the message is saved locally with `syncState = pending`
**And** the app POSTs it to the Core API with the session JWT
**And** on confirmation the local message records its `serverId` and becomes `synced`

---

### Requirement: Offline Queue and Replay

When the device is offline, the iOS app SHALL queue patient messages locally and
SHALL replay them to the Core API when connectivity returns. Cached conversations
SHALL remain readable while offline.

#### Scenario: An offline message is queued and replayed

**Given** the device has no connectivity
**When** the patient sends a message
**Then** the message is saved locally with `syncState = pending`
**And** when connectivity returns the app replays it to the Core API
**And** the message becomes `synced` after confirmation

#### Scenario: Cached conversations are readable offline

**Given** the device has no connectivity
**When** the patient opens a previously synced conversation
**Then** its messages are served from the local cache

---

### Requirement: Recommendation Delivery Receipt

The iOS app SHALL NOT display AI-generated content inline at send time. It SHALL
display assistant content only when the Core API delivers a recommendation —
received via the WebSocket channel (or a poll fallback) — so that nothing
unreviewed by a physician is shown to the patient.

#### Scenario: A delivered recommendation appears as the assistant reply

**Given** a patient who has sent a message that synced to the Core API
**When** the Core API delivers a physician-approved recommendation for it
**Then** the app receives the `recommendation.delivered` event
**And** the recommendation content is shown as the assistant message in the conversation

#### Scenario: No assistant content before delivery

**Given** a patient who has sent a message that synced to the Core API
**When** no recommendation has reached the `DELIVERED` state yet
**Then** the conversation shows no assistant reply for that message

---

### Requirement: Inline Recommendation Card Rendering

The iOS app SHALL render a delivered Recommendation as an inline action card
within the chat conversation, keyed off the recommendation's `payload_type`.
The MVP SHALL implement a single `guidance` card type that displays the
delivered text; the renderer SHALL be structured so that future
`prescription`, `lab_order`, and `referral` card types can be added without
restructuring the chat surface.

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
