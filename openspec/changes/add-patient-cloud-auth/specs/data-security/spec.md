# data-security (delta)

## ADDED Requirements

### Requirement: Encryption Identity Continuity Under Cloud Auth

Moving patient credential authority to the Core API SHALL NOT change how PHI is
encrypted at rest. The AES-256-GCM master key SHALL remain generated and stored
on the device and SHALL never be transmitted to, or derived from, the Core API or
the authentication token. Per-user PHI keys SHALL be HKDF-derived using the
canonical patient identity as the stable salt so that encrypted data remains
readable across sessions for the same patient.

#### Scenario: Keys stay device-local under cloud auth

- **GIVEN** a patient authenticated via the Core API
- **WHEN** PHI is encrypted or decrypted on the device
- **THEN** the master key is read only from the device Keychain
- **AND** neither the master key nor any derived key is sent to the Core API
- **AND** the authentication token is not used as key material

#### Scenario: Stable identity keeps data readable

- **GIVEN** PHI previously encrypted for a patient's canonical identity
- **WHEN** the same patient authenticates again on the same device
- **THEN** the derived key for that canonical identity reproduces and the PHI decrypts
