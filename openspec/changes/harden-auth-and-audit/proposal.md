# Proposal: Harden Authentication, Sessions and Audit

## Why

The backend gets the basics right (bcrypt cost 12, a single HS256
implementation with a fixed algorithm, `HttpOnly`/`Secure`/`SameSite` cookies,
tenant-scoped queries), but several controls a HIPAA production system is
expected to have are missing:

- **No rate limiting anywhere.** Login can be brute-forced, and registration's
  409 response reveals which emails have accounts (bead `HouseCall-wfug`).
- **No second factor for physicians.** A physician password alone opens every
  patient's record in the review queue.
- **Long-lived, unrevocable tokens.** Patient API tokens and physician web
  sessions last 24 hours (`api/jwt.go`, `web/token.go`), cannot be revoked on
  logout, and the web session has no idle timeout.
- **WebSocket token in the URL.** Mobile clients pass the JWT as `?token=`
  (`api/ws.go`), where it ends up in proxy and load-balancer access logs.
- **API reads are not audited.** The portal already audits panel and queue
  views (`web.panel.viewed`, `web.queue.viewed`), but Core API reads of
  messages and recommendations write nothing. HIPAA expects a record of who
  accessed which patient's data on every surface.
- **Portal responses lack hardening:** no Content-Security-Policy, HSTS,
  `no-store` on PHI pages, or CSRF token on POST forms.

These are cheaper to build now, with one developer and no users, than after
the AWS move.

## What Changes

- **MODIFIED** `core-api` / Authenticated API Access: 15-minute access tokens
  with an audience claim, plus WebSocket connections authenticated by ticket.
- **ADDED** `core-api` / Refresh Token Rotation: single-use refresh tokens,
  stored hashed, rotated on use, revoked on logout and on reuse.
- **ADDED** `core-api` / WebSocket Connection Tickets: a short-lived, single-use
  ticket replaces the JWT in the WebSocket URL.
- **ADDED** `core-api` / Request Rate Limiting on login, registration, message
  posting and ticket issue.
- **MODIFIED** `core-api` / Audit Logging: PHI reads are audited.
- **MODIFIED** `physician-web-app` / Physician Authentication: TOTP second
  factor, server-side revocable sessions, 30-minute idle timeout and 12-hour
  absolute lifetime.
- **ADDED** `physician-web-app` / Portal Response Hardening: security headers
  and CSRF tokens.
- **MODIFIED** `authentication` / Core API Session Token Lifecycle: the iOS app
  refreshes silently once before asking the patient to sign in again.

## Impact

- **Affected specs**: `core-api`, `physician-web-app`, `authentication`.
- **Affected code**: `backend/internal/api` (auth, jwt, ws, router,
  middleware), `backend/internal/web` (login, sessions, templates),
  `backend/internal/jwtutil`, `backend/internal/audit`,
  `backend/internal/store`, `backend/migrations` (refresh tokens, web sessions,
  physician MFA), iOS `Core/Services/Sync/` and `AuthenticationService`.
- **New dependencies**: `golang.org/x/time/rate` (rate limiting) and
  `github.com/pquerna/otp` (TOTP). Both are widely used and small.
- **Dependencies**: best after `simplify-ios-cloud-client`, which leaves one
  iOS sign-in path to update instead of two.
- **Out of scope**: encryption of PHI columns at the application level (stays
  with storage-level encryption on the production database; decided in
  `add-production-security-hardening`), CAPTCHA, SSO, WebAuthn.
