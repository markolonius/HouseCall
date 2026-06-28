# Tasks: Patient Cloud Authentication

## Phase 1: Core API patient registration endpoint

### Task 1.1: Add POST /api/auth/register  [x]
Add a registration handler mirroring `handleLogin` validation (tenant_id, email,
password required). Create a tenant-scoped patient with a bcrypt password hash,
reject duplicate email within tenant (409), issue + return a JWT (same response
shape as login). Wire the route in `router.go`.

### Task 1.2: Audit + store wiring  [x]
Write a `patient.registered` audit event (identifiers only — never password/PHI).
Add/confirm the store patient-creation path used by registration is tenant-scoped.
Tests: happy path, duplicate email, missing fields, and that the returned token
authenticates a subsequent `/api/*` request.

## Phase 2: iOS Core API auth client

### Task 2.1: Core API login/register client
Add `login(tenantId:email:password:)` and `register(tenantId:email:password:)` to
the Core API client surface (extend `SyncClient` or a small `CoreAPIAuthClient`
sharing baseURL + URLSession), returning `{token, patientId}`. Never log the
password. Unit tests with a stubbed URLSession (success, 401, 409, unreachable).

## Phase 3: Make Core API authoritative in AuthenticationService

### Task 3.1: Registration flow through Core API
`AuthenticationService.register` calls the Core API register client, then creates
the local cache user keyed by the returned `patientId`, sets up the device master
key + derived key (encryption identity = `patientId`), and stores the JWT.

### Task 3.2: Login flow through Core API + encryption-identity continuity
`AuthenticationService.login` authenticates against Core API; on success stores
the JWT, ensures the local cache user for `patientId`, unlocks encryption for
`patientId`, starts the session. Confirm HKDF salt = canonical `patientId` so PHI
keys stay device-local and stable. 401 → reject.

## Phase 4: Offline fallback + session/JWT lifecycle

### Task 4.1: Offline fallback login
When Core API is unreachable (network/timeout, not 401), fall back to the cached
local credential check so the patient can open their encrypted local record;
cloud sync stays inactive until a JWT is obtained. Distinguish unreachable vs
rejected.

### Task 4.2: Logout + 401 handling
Logout clears session, cached derived key, and `coreAPIJWT`. On a `401` from
`SyncClient`, deactivate cloud sync and require re-login (no retry loop).

## Phase 5: Tenant config + cloud activation

### Task 5.1: CoreAPITenantID config
Add `CoreAPITenantID` build setting → Info.plist (alongside `CoreAPIBaseURL`),
read in the auth/coordinator wiring. Empty → cloud auth disabled (pure local
mode, no regression).

### Task 5.2: Activate cloud sync when authenticated
With base URL + tenant + JWT present, the existing `CloudSyncCoordinator` gate
activates after login. Verify a logged-in patient's messages route through Core
API and agent interview questions arrive over WebSocket (resolves HouseCall-nre3).

## Phase 6: Tests and end-to-end evaluation

### Task 6.1: Backend + iOS auth tests
Backend: register endpoint tests (phase 1). iOS: AuthenticationService register/
login through Core API, offline fallback, logout JWT clearing, encryption-
identity continuity (same patientId → same derived key).

### Task 6.2: Manual end-to-end evaluation
With Postgres + core-api + agent (Ollama `medgemma:4b`) + physician web app
running: register a patient in-app, conduct the interview, confirm the SOAP note
reaches the physician queue, approve it, and confirm the approved plan is
delivered back to the patient app. Closes HouseCall-nre3 and
add-clinical-soap-review-workflow task 6.3.
