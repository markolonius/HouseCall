# Design: Patient Trust Surface

## Reviewer attribution

- Migration adds `physicians.credential text NOT NULL DEFAULT ''` (for example
  `MD`). The seed physician gets `MD`.
- The recommendation DTO for `DELIVERED` recommendations adds
  `reviewer: {name, credential, license_state}`, `reviewed_at`, and
  `edited: bool` (true when the transition went through `MODIFIED`).
  `license_state` is the patient's state, which the `State-Licensed Physician
  Action` rule guarantees is in the physician's `states_licensed`.
- Non-delivered recommendations are never returned to patients, so the DTO
  change exposes nothing new before delivery.

## Access log

- `GET /api/me/access-log?before=<cursor>&limit=50` returns entries derived
  from audit events whose metadata references the caller's `patient_id`:
  `{at, actor: {type, display_name}, action}`.
- `actor.type` is `physician` (display name from `physicians.full_name`),
  `assistant` (shown as "HouseCall assistant"), or `self`. Internal system
  events (migrations, background jobs) are excluded.
- `action` is a small fixed vocabulary mapped from event types: "viewed your
  messages", "reviewed a recommendation", "drafted a note", "signed in",
  "exported your records". Event types without a mapping are not shown.
- Reading the access log does not itself write an access-log entry (avoids an
  entry every time the screen opens); it writes a normal audit event that is not
  surfaced.

## Export

- `GET /api/me/export` returns `application/json`: profile (email, name,
  state), conversations with messages, delivered recommendations with reviewer
  attribution, and the access log. Generated synchronously; volume per patient
  is small.
- Rate-limited to 5 per day per patient and audited (`records_exported`).
- iOS saves the response to a temporary file and opens the share sheet. The
  temporary file is deleted after the share sheet closes.

## Account closure

- `POST /api/me/closure` with the current password. It sets
  `patients.closed_at`, revokes every refresh token family, and writes an audit
  event. A closed account cannot sign in; registration with the same email is
  allowed only after the records are deleted.
- Clinical data (messages, recommendations, audit events) is retained until
  `closed_at + RECORD_RETENTION_YEARS` (default 7), then deleted by a scheduled
  job. That job is listed as a follow-up task, because nothing reaches the
  retention date for 7 years.
- The app explains this before confirming: "Your account will be closed now.
  Medical records are kept for 7 years as the law requires, then deleted."
- iOS clears the Keychain and the local encrypted cache after a successful
  closure.

## iOS

- `RecommendationCard` shows the reviewer line and the edited indicator for
  delivered recommendations; older recommendations without attribution show
  the card as today.
- `ProfileView` gains three rows: Access history, Download my records, Close
  account. Each is reachable with VoiceOver and Dynamic Type.
