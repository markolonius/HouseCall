# Proposal: Patient Trust Surface

## Why

`docs/POSITIONING.md` makes trust a product feature, not a privacy page: "Put
the clinician on the screen", "Give every patient a personal access log",
"One-tap export and delete". It names these as how HouseCall differs from a
funded, free competitor that also has physician review and HIPAA claims.

None of them exist in the app today. A delivered recommendation appears as a
card with text only (`RecommendationCard.swift`), with no sign of who reviewed
it. The audit trail exists server-side but the patient cannot see it, and there
is no way to export one's records or close an account.

The data is mostly there already: `recommendations.reviewed_by` and
`reviewed_at` identify the reviewing physician, `physicians.states_licensed`
holds the licence states, and the audit log records access (`phi_read` from
`harden-auth-and-audit`).

## What Changes

- **ADDED** `core-api` / Recommendation Reviewer Attribution: delivered
  recommendations carry the reviewing physician's name, credential and licence
  state, the review time, and whether the physician edited the draft.
- **MODIFIED** `ios-cloud-sync` / Inline Recommendation Card Rendering: the card
  shows "Reviewed by Dr. <name>, <credential> · licensed in <state>" and an
  "Edited by your physician" indicator.
- **ADDED** `core-api` / Patient Access Log: a patient can list who accessed
  their records and when (physician, the HouseCall assistant, or themselves),
  without content.
- **ADDED** `core-api` / Patient Data Export: a patient can download their
  profile, conversations and delivered recommendations as one JSON file (HIPAA
  right of access, 45 CFR § 164.524).
- **ADDED** `core-api` / Account Closure: a patient can close their account.
  Sign-in is disabled and tokens revoked; clinical records are retained for the
  legally required period and then deleted.
- **ADDED** `ai-chat-interface` / Trust Controls in Profile: the Profile screen
  offers the access log, export and account closure.

## Impact

- **Affected specs**: `core-api`, `ios-cloud-sync`, `ai-chat-interface`.
- **Affected code**: `backend/internal/api` (new `/api/me/*` routes,
  recommendation DTO), `backend/internal/store`, `backend/migrations`
  (`physicians.credential`, patient closure fields), iOS `RecommendationCard`,
  `ProfileView`, `Core/Services/Sync/`.
- **Dependencies**: `harden-auth-and-audit` (the access log reads `phi_read`
  events and closure revokes refresh tokens). Best after
  `simplify-ios-cloud-client`.
- **Out of scope**: FHIR export, a public Trust Center web page, physician
  photos.

## Deliberately not included: showing the AI draft to the patient

`POSITIONING.md` suggests showing "the AI's draft next to the physician's final
edits". That would show the patient AI-written clinical text the physician did
not approve, which breaks the `physician-in-loop` rule that no unapproved
clinical content reaches the patient. This change shows only that the physician
edited the draft. Revisit with clinical and legal advice if wanted.

## Open Questions

- Record retention period: Pennsylvania requires physicians to keep adult
  records for at least 7 years after the last service (to be confirmed with
  counsel). The design uses 7 years as a configurable value.
- Credential display: `MD`/`DO` from a new column, entered when the physician
  account is created.
