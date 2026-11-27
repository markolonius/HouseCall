# authentication (delta)

## REMOVED Requirements

### Requirement: 6-Digit Passcode as Authentication Alternative
**Reason**: The Core API authenticates patients by email and password only, so a passcode cannot be the source-of-truth credential. Biometric unlock already covers fast re-entry to a previously authenticated session.
**Migration**: No production users exist. Development accounts created with a passcode must be re-registered with a password.
