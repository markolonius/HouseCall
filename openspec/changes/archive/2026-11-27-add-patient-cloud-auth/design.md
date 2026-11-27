# Design: Patient Cloud Authentication

## Existing pieces (reused)

- Core API `POST /api/auth/login` (`internal/api/auth.go::handleLogin`): tries
  patient-then-physician by email, bcrypt-compares, issues an HMAC JWT
  (`issueToken`). `requireAuth` validates the Bearer token on `/api/*`.
- iOS `AuthenticationService.storeCoreAPIJWT(_:)` / `clearCoreAPIJWT()` already
  write/delete `KeychainManager.Keys.coreAPIJWT` — currently never called by a
  real Core API login.
- iOS `EncryptionManager`: device-local AES-256-GCM master key in the Keychain;
  per-user key = `HKDF(masterKey, salt = userId.uuidString)`.
- Config-gated `CloudSyncCoordinator` (from the SOAP change) activates only when
  `CoreAPIBaseURL` is set AND a `coreAPIJWT` exists.

## The hard part: credentials move, encryption stays local

Making Core API authoritative for credentials must NOT change how PHI is
encrypted at rest, because:

- The master key is device-local and must never leave the device or be derived
  from a server secret.
- Existing per-user keys are HKDF-salted by a UUID. The salt identity must remain
  stable for a given patient or previously-encrypted data becomes unreadable.

**Approach — canonical patient identity = Core API patient UUID.**
- On Core API login/register, the response carries the patient's Core API UUID.
- The iOS local user record is keyed by that same UUID, and that UUID is the HKDF
  salt. So the encryption identity is the Core API patient id from creation
  onward — consistent across devices' *credential* checks while keys stay local
  to each device.
- The device master key remains generated/stored locally on first setup
  (unchanged). Encryption keys are therefore device-local but salted by a
  server-canonical id — credentials and keys stay cleanly separated.
- Pre-launch: no production data to migrate. Existing local-only test accounts
  may not carry over; that is acceptable and called out in scope.

## Flows

### Registration (iOS SignUp)
1. iOS calls `POST /api/auth/register {tenant_id, email, password}`.
2. Core API creates the patient (bcrypt password), audits `patient.registered`
   (identifiers only), returns `{token, patient_id}` (same shape as login).
3. iOS creates the local cache user keyed by `patient_id`, sets up the device
   master key / derived key (encryption identity = `patient_id`), and stores the
   JWT via `storeCoreAPIJWT`.

### Login (iOS)
1. iOS calls `POST /api/auth/login {tenant_id, email, password}`.
2. On success: store JWT, ensure the local cache user exists for `patient_id`,
   unlock encryption (derive key for `patient_id`), start the session.
3. On Core API auth failure (401): reject — Core API is authoritative.
4. On Core API UNREACHABLE (network/timeout): fall back to the cached local
   credential check so the patient can still open their encrypted local record
   offline; cloud sync stays inactive (no fresh JWT) until connectivity returns.

### Logout
- Clear the session, the cached derived key, AND the `coreAPIJWT`
  (`clearCoreAPIJWT`).

### JWT lifecycle
- The JWT is short-lived/HMAC. On a `401` from any `SyncClient` call, the
  coordinator should surface re-auth (silently re-login if a cached credential is
  available, else require interactive login). MVP: on 401, deactivate cloud sync
  and prompt re-login; do not loop.

## Backend: register endpoint
- `POST /api/auth/register` mirrors `handleLogin` validation (tenant_id, email,
  password required). Reject duplicate email within tenant (409). Hash with
  bcrypt (same cost as existing physician/patient hashing). Create patient row
  (tenant-scoped), write `patient.registered` audit (identifiers only — never the
  password or PHI), issue + return a JWT so the client is logged in immediately.
- Reuse `issueToken`, the store's patient creation path, and the audit writer.

## iOS: Core API auth client
- Add login/register to the Core API client surface (extend `SyncClient` or a
  small dedicated `CoreAPIAuthClient` sharing the base URL + `URLSession`). It is
  the only component that sends the plaintext password (over TLS) to Core API; it
  never logs it. Returns `{token, patientId}`.
- `AuthenticationService.register`/`login` orchestrate: call the client, manage
  JWT + local cache user + encryption unlock + session, with the offline
  fallback above.

## Tenant config
- `CoreAPITenantID` build setting → Info.plist, read alongside `CoreAPIBaseURL`.
  Empty → cloud auth disabled (pure local mode, current behavior) so the default
  build still runs without a backend.

## Safety / HIPAA
- Password sent only to Core API over TLS; never logged on either side.
- Encryption master key never leaves the device; keys never derived from server
  secrets; JWT is not an encryption input.
- Audit: `patient.registered` / login events carry identifiers only.
- Offline fallback never weakens encryption — it only gates app entry via the
  cached local credential; the data is still AES-GCM encrypted at rest.

## Alternatives considered
- **Dual auth (keep local authoritative, add cloud alongside)** — rejected per
  decision; leaves two drifting credential stores.
- **Auto-provision on first login** — rejected; muddies the registration audit
  trail vs an explicit register endpoint.
