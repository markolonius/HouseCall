# Design: Harden Authentication, Sessions and Audit

## Tokens

- **Access tokens** (patient API): HS256 JWT, 15-minute lifetime, claims gain
  `aud: "patient-api"`. Verification rejects any other audience.
- **Refresh tokens**: 32 random bytes, base64url, returned at login and
  registration. Stored as SHA-256 hashes in a new `refresh_tokens` table
  (`id, tenant_id, patient_id, token_hash, family_id, expires_at, used_at,
  revoked_at`). Lifetime 30 days.
- `POST /api/auth/refresh` exchanges a refresh token for a new access token and
  a new refresh token, marking the old one used. Presenting an already-used
  token revokes its whole family (theft signal) and writes an audit event.
- `POST /api/auth/logout` revokes the presented refresh token's family.
- iOS keeps both in the Keychain (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
  as today). On a 401 it calls refresh once; if refresh fails it falls back to
  the read-only state from `simplify-ios-cloud-client`.

## Physician web sessions

- Replace the JWT-in-cookie with an opaque session ID (32 random bytes) stored
  hashed in `web_sessions` (`id, tenant_id, physician_id, created_at,
  last_seen_at, mfa_verified_at, revoked_at`).
- Idle timeout 30 minutes, absolute lifetime 12 hours, logout revokes the row.
  `last_seen_at` updates at most once a minute to limit writes.
- Physicians no longer receive a JWT from `POST /api/auth/login`; that endpoint
  becomes patient-only. The physician review API (`POST
  /api/recommendations/{id}/review`) moves behind the web session. If a
  physician API client is needed later, it gets its own change.

## TOTP second factor

- Enrolment on first login after this change: the portal shows a QR code (RFC
  6238, SHA-1, 6 digits, 30 seconds, for authenticator-app compatibility) and
  requires one valid code before saving. Secrets are stored encrypted with a key
  from `MFA_ENCRYPTION_KEY` (AES-GCM), never logged.
- Ten single-use recovery codes are shown once and stored as bcrypt hashes.
- A session is not `mfa_verified` until a code is accepted. No patient data is
  rendered before that.
- Codes are accepted for the current and previous 30-second step only, and a
  code already used in its step is rejected (replay).

## WebSocket tickets

- `POST /api/ws/ticket` (authenticated) returns a 32-byte random ticket valid
  for 30 seconds and usable once. The WebSocket upgrade accepts `?ticket=` and
  rejects `?token=`.
- Tickets live in an in-process map with expiry. That is correct for one API
  instance. Multiple instances (AWS) need a shared store or sticky sessions;
  that is noted for the production change.

## Rate limiting

In-process token buckets (`golang.org/x/time/rate`), keyed as below; 429 with
`Retry-After` when exceeded:

| Route | Key | Limit |
|---|---|---|
| `POST /api/auth/login`, `/web/login` | IP and email | 5/min per email, 20/min per IP |
| `POST /api/auth/register` | IP | 5/hour |
| `POST /api/auth/refresh` | IP | 30/min |
| `POST /api/conversations/{id}/messages` | patient | 30/min |
| `POST /api/ws/ticket` | patient | 10/min |
| TOTP verification | physician | 5/min, lockout 15 min after 10 failures |

- The client IP comes from `X-Forwarded-For` only when
  `TRUSTED_PROXY_CIDRS` is set; otherwise the socket address. This stops
  spoofed headers from evading limits.
- In-process buckets reset on restart and are per-instance. Acceptable for one
  instance; the AWS change moves them to the load balancer/WAF or a shared
  store.
- Registration still returns 409 for an existing email (the iOS app relies on
  it). Rate limiting bounds enumeration; a non-revealing flow is a later
  decision tracked in `HouseCall-wfug`.

## Read auditing

- New event type `phi_read` with metadata `{resource_type, resource_id,
  patient_id}` only. Never content.
- Written for API `GET` of conversation messages, the recommendation list and a
  single recommendation.
- The portal's existing `web.panel.viewed` and `web.queue.viewed` events stay as
  they are; they already record one event per page view, which keeps volume
  reasonable. The only web addition is recommendation detail views, if they are
  not already covered by those events.

## Portal response hardening

All `/web` responses set:
- `Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; form-action 'self'`
- `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`
- `Cache-Control: no-store` on any page with patient data
- `Strict-Transport-Security: max-age=31536000` when served over HTTPS

POST forms (login, MFA, review actions, logout) carry a per-session CSRF token
checked in middleware; a missing or wrong token returns 403.

## Configuration

New environment variables: `MFA_ENCRYPTION_KEY`, `TRUSTED_PROXY_CIDRS`.
`JWT_SECRET` stays for access tokens only. Production startup refuses the dev
default secrets.
