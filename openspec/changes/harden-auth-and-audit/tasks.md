# Tasks: Harden Authentication, Sessions and Audit

## Phase 1 — Rate limiting and read auditing

- [ ] 1.1 Rate-limit middleware
  - Token buckets per the table in `design.md`; 429 with `Retry-After`; trusted-proxy IP extraction.
  - Unit tests per route key, including spoofed `X-Forwarded-For` without `TRUSTED_PROXY_CIDRS`.
- [ ] 1.2 `phi_read` audit events for API reads
  - API message, recommendation list and recommendation detail reads; keep the existing web view events, adding recommendation detail views only if uncovered.
  - Tests assert the event is written and contains no content fields.

## Phase 2 — Patient tokens

- [ ] 2.1 Short access tokens with audience
  - 15-minute TTL, `aud: "patient-api"`, verification rejects other audiences; tests.
- [ ] 2.2 Refresh token rotation
  - Migration for `refresh_tokens`; `POST /api/auth/refresh` and `POST /api/auth/logout`; reuse revokes the family and audits.
  - Tests: rotate, reuse detection, logout, expiry, cross-tenant token rejected.
- [ ] 2.3 WebSocket tickets
  - `POST /api/ws/ticket`; upgrade accepts `?ticket=` once within 30 seconds and rejects `?token=`; tests for expiry and reuse.
- [ ] 2.4 iOS: refresh and tickets
  - Store the refresh token in the Keychain; refresh once on 401, then read-only state; request a ticket before each WebSocket connect; logout calls the API.
  - `scripts/test.sh` passes.

## Phase 3 — Physician sessions and MFA

- [ ] 3.1 Server-side web sessions
  - Migration for `web_sessions`; opaque cookie; 30-minute idle and 12-hour absolute timeouts; logout revokes.
  - `POST /api/auth/login` becomes patient-only; the review API moves behind the web session.
- [ ] 3.2 TOTP enrolment and verification
  - Migration for physician MFA secret (encrypted) and recovery codes (hashed); enrolment page with QR; verification page; replay and rate-limit protection.
  - No patient data rendered before `mfa_verified`; tests for each state.
- [ ] 3.3 Portal response hardening
  - Security headers middleware and CSRF tokens on every POST form; tests assert headers and 403 on a bad token.

## Phase 4 — Verification

- [ ] 4.1 Production startup refuses dev-default `JWT_SECRET` and a missing `MFA_ENCRYPTION_KEY`; test.
- [ ] 4.2 Manual smoke: patient login → token expiry → silent refresh → logout; physician first login → MFA enrolment → review → idle timeout.
- [ ] 4.3 Update `backend/README.md` (new env vars, MFA setup for the seed physician) and `openspec validate harden-auth-and-audit --strict`.
