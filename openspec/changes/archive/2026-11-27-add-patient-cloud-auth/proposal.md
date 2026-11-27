# Proposal: Patient Cloud Authentication (Core API as Source of Truth)

## Why

`add-clinical-soap-review-workflow` built the full server-side interview → SOAP →
physician-approval → delivery loop, but the patient app can't reach it: the iOS
cloud path requires a Core API JWT (`KeychainManager.Keys.coreAPIJWT`), and the
patient logs in only against the local Core Data store — no JWT is ever obtained.
The `CloudSyncCoordinator` therefore stays gated off and the app falls back to
direct-LLM (tracked as `HouseCall-nre3`).

Core API already exposes `POST /api/auth/login` (patient-or-physician, returns an
HMAC JWT), but there is no patient registration route and the iOS app never calls
either endpoint. This change makes the Core API the source of truth for patient
authentication, adds patient registration, and wires the iOS auth flow to obtain
and cache the JWT — unblocking the cloud SOAP loop end-to-end.

## What Changes

- **NEW** `POST /api/auth/register` on Core API: creates a tenant-scoped patient
  (email + bcrypt password), audited, returning the same token shape as login.
- **Core API as patient auth source of truth.** iOS registration and login go
  through Core API; the local Core Data user becomes a device-local cache used
  for offline access and (critically) for PHI encryption-key derivation. On
  successful Core API login the returned JWT is cached in the Keychain
  (`storeCoreAPIJWT`, already present) so `SyncClient`/`CloudSyncCoordinator` can
  authenticate.
- **Encryption-identity continuity.** PHI encryption stays device-local and
  unchanged in mechanism: the AES-256-GCM master key remains in the device
  Keychain and per-user keys are HKDF-derived from a stable canonical patient
  identity. Credentials move to Core API, but encryption keys are never sent to
  or derived from the server.
- **Offline fallback.** When Core API is unreachable, the patient can still
  unlock the app via the cached local credential (so the encrypted local record
  remains accessible); Core API remains authoritative when reachable, and cloud
  sync activates only with a valid JWT.
- **Tenant configuration.** A single-tenant MVP tenant id is supplied by build
  config (alongside the existing `CoreAPIBaseURL`).
- **Cloud activation.** With a JWT present, the existing config-gated
  `CloudSyncCoordinator` activates, resolving `HouseCall-nre3` and making the
  patient→interview→SOAP→approval→delivery loop reachable from the app.

## Impact

- **Affected specs**: `core-api` (ADDED patient registration), `authentication`
  (MODIFIED registration + login to be Core-API-authoritative; ADDED Core API
  session token handling + offline fallback), `data-security` (ADDED encryption-
  identity continuity guarantee), `ios-cloud-sync` (ADDED authenticated cloud
  activation).
- **Affected code**: backend `internal/api/auth.go` + `router.go` + `store`
  (CreatePatient/register, audit); iOS `AuthenticationService` (register/login
  flows, JWT lifecycle), a Core API auth client (extend `SyncClient` or a small
  `CoreAPIAuthClient`), `EncryptionManager` identity continuity, config
  (`CoreAPITenantID`), and activation of the existing `CloudSyncCoordinator` gate.
- **Resolves**: `HouseCall-nre3`. Unblocks `add-clinical-soap-review-workflow`
  task 6.3 (manual e2e).
- **Out of scope**: physician registration UI (physicians remain seeded/managed
  separately); OIDC/Cognito (the `requireAuth` comment notes it plugs in later);
  password reset / email verification; multi-tenant onboarding; migrating any
  pre-existing local-only accounts (pre-launch, no production data).
