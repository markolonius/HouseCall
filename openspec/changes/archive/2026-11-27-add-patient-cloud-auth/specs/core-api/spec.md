# core-api (delta)

## ADDED Requirements

### Requirement: Patient Registration

The Core API SHALL provide a registration endpoint that creates a tenant-scoped
patient from an email and password, storing the password as a bcrypt hash, and
SHALL return an authentication token so the client is immediately authenticated.
Registration SHALL reject a duplicate email within the same tenant and SHALL
write an audit event containing identifiers only.

#### Scenario: New patient registers

- **GIVEN** a valid tenant and an email not yet registered in that tenant
- **WHEN** the client POSTs the email and password to the registration endpoint
- **THEN** a patient record is created in that tenant with a bcrypt password hash
- **AND** an authentication token is returned
- **AND** a `patient.registered` audit event is written with identifiers only (no password, no PHI)

#### Scenario: Duplicate email is rejected

- **GIVEN** an email already registered within the tenant
- **WHEN** the client attempts to register that email again
- **THEN** the request is rejected as a conflict
- **AND** no second patient record is created

#### Scenario: Missing fields are rejected

- **GIVEN** a registration request missing tenant, email, or password
- **WHEN** the request is processed
- **THEN** it is rejected as a bad request
- **AND** no patient record is created

#### Scenario: Returned token authenticates API access

- **GIVEN** a successful registration
- **WHEN** the returned token is used as a Bearer token on an authenticated `/api/*` request
- **THEN** the request is accepted as that patient within the tenant
