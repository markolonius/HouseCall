# Tasks: Patient Trust Surface

Prerequisite: `harden-auth-and-audit` merged (access log reads `phi_read`; closure revokes refresh tokens).

## Phase 1 — Reviewer attribution

- [ ] 1.1 Physician credential and attribution in the API
  - Migration adds `physicians.credential`; seed sets `MD`.
  - Delivered recommendation DTO includes `reviewer`, `reviewed_at`, `edited`; tests confirm nothing new is returned before delivery.
- [ ] 1.2 Reviewer line on the iOS card
  - `RecommendationCard` shows "Reviewed by Dr. <name>, <credential> · licensed in <state>" and "Edited by your physician" when `edited`; degrades to today's card without attribution.
  - `scripts/test.sh` passes.

## Phase 2 — Access log and export

- [ ] 2.1 Access log endpoint
  - `GET /api/me/access-log` with cursor pagination and the fixed action vocabulary; excludes system events; tenant- and patient-scoped.
  - Tests: physician read appears, another patient's events never appear, unmapped events hidden.
- [ ] 2.2 Export endpoint
  - `GET /api/me/export` JSON bundle; rate limit 5/day; `records_exported` audit event; tests.
- [ ] 2.3 iOS access history and download
  - Profile rows for Access history (paginated list) and Download my records (share sheet, temp file removed afterwards).

## Phase 3 — Account closure

- [ ] 3.1 Closure endpoint
  - `POST /api/me/closure` with password confirmation; sets `closed_at`, revokes refresh tokens, audits; closed accounts cannot sign in; tests.
- [ ] 3.2 iOS close account
  - Profile row with the retention explanation and confirmation; clears Keychain and the local cache on success.

## Phase 4 — Verification

- [ ] 4.1 Manual smoke: delivered recommendation shows reviewer; physician view appears in access history; export opens the share sheet; closure signs the patient out and blocks sign-in.
- [ ] 4.2 File a bead for the retention deletion job (due before the first retention date), update `docs/USER_GUIDE.md`, and `openspec validate add-patient-trust-surface --strict`.
