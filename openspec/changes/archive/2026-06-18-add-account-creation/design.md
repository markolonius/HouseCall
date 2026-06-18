# Design: HIPAA-Compliant Account Creation

## Context
HouseCall is a healthcare application subject to HIPAA regulations from day one. Even with local-only storage in MVP, all user data (email, name, password hash) constitutes Protected Health Information (PHI) when associated with health records. The authentication system must implement defense-in-depth security with encryption at rest, secure credential storage, and comprehensive audit logging.

**Constraints**:
- iOS 15+ platform (LocalAuthentication, CryptoKit available)
- No backend API in MVP (local-only storage)
- HIPAA Technical Safeguards required (45 CFR § 164.312)
- SwiftUI declarative UI with MVVM architecture
- Must support offline-first operation

**Stakeholders**:
- Patients: Simple, secure account creation
- Physicians: Trust in data security and compliance
- Compliance officers: HIPAA audit trail and encryption standards
- Developers: Maintainable, testable security architecture

## Goals / Non-Goals

### Goals
- ✅ HIPAA-compliant user account creation with full encryption
- ✅ Email/password + biometric (Face ID/Touch ID) authentication
- ✅ Collect minimal PII: email, password, full name
- ✅ Encrypted Core Data storage with AES-256
- ✅ Secure keychain storage for sensitive credentials
- ✅ Password strength validation (healthcare-grade requirements)
- ✅ Email format validation
- ✅ Audit logging for all authentication events
- ✅ Graceful error handling (no crashes on data errors)
- ✅ Accessibility compliance (WCAG 2.1 AA)
- ✅ Direct navigation to AI chat interface post-registration

### Non-Goals
- ❌ Backend API integration (future phase)
- ❌ Email verification via OTP (requires backend)
- ❌ Password reset flow (requires backend)
- ❌ Multi-factor authentication beyond biometrics (future)
- ❌ Social login (Apple Sign In, Google)
- ❌ Medical history collection during registration (AI will handle)
- ❌ Terms of Service / Privacy Policy screens (content not ready)

## Decisions

### Decision 1: Core Data + Encrypted Attributes for User Storage
**Choice**: Use Core Data with `NSPersistentStoreFileProtectionKey` and field-level encryption for sensitive attributes.

**Rationale**:
- Core Data already integrated in project template
- `NSFileProtectionComplete` provides iOS-level encryption at rest
- Additional field-level encryption (AES-256-GCM) for password hash and PII
- Meets HIPAA requirement for encryption at rest (45 CFR § 164.312(a)(2)(iv))
- Local-only storage satisfies MVP requirement (no network complexity)

**Alternatives considered**:
- SQLCipher: More complex integration, requires third-party dependency
- Keychain-only storage: Not suitable for complex user profiles
- Plain Core Data: Insufficient for HIPAA compliance

**Implementation**:
```swift
// User entity with encrypted attributes
class User: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var email: String  // Encrypted at field level
    @NSManaged var encryptedPasswordHash: Data  // Bcrypt hash, then encrypted
    @NSManaged var encryptedFullName: Data  // AES-256-GCM encrypted
    @NSManaged var createdAt: Date
    @NSManaged var lastLoginAt: Date?
    @NSManaged var biometricEnabled: Bool
}
```

### Decision 2: CryptoKit for Field-Level Encryption
**Choice**: Use CryptoKit's `AES.GCM` for field-level encryption of PII.

**Rationale**:
- Native iOS framework (no third-party dependencies)
- FIPS 140-2 compliant encryption algorithms
- Modern Swift API with proper error handling
- Supports authenticated encryption (detects tampering)
- Key derivation from user-specific salt + device-bound master key

**Alternatives considered**:
- CommonCrypto: Older C API, more complex to use
- Third-party libraries: Adds security audit burden
- Server-side encryption only: Not viable for local-only MVP

**Key Management Strategy**:
```
Master Key (256-bit) -> Stored in Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
  ↓
User-Specific Derived Key = HKDF(Master Key, User ID as salt)
  ↓
Encrypt each PII field with AES-256-GCM using derived key + random nonce
```

### Decision 3: Keychain for Master Encryption Key and Session Token
**Choice**: Store master encryption key and active session token in iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.

**Rationale**:
- Keychain provides hardware-backed encryption on devices with Secure Enclave
- `WhenUnlockedThisDeviceOnly` prevents iCloud backup and requires device unlock
- Meets HIPAA access control requirements (45 CFR § 164.312(a)(1))
- Automatic cleanup when app is uninstalled (no orphaned keys)

**Keychain Items**:
- `com.housecall.master-encryption-key`: 256-bit AES key for field encryption
- `com.housecall.session-token`: UUID representing active authenticated session
- `com.housecall.biometric-enrollment`: Flag indicating biometric setup completion

### Decision 4: Bcrypt for Password Hashing
**Choice**: Use bcrypt with cost factor 12 for password hashing before encryption.

**Rationale**:
- Industry standard for password hashing (OWASP recommended)
- Adaptive cost factor (future-proof against hardware improvements)
- Resistant to rainbow table and GPU-based attacks
- Additional encryption layer (hash is encrypted before Core Data storage)

**Alternatives considered**:
- PBKDF2: Supported, but bcrypt preferred for password hashing
- Argon2: Modern but requires third-party library
- Plain SHA-256: Cryptographically broken for passwords

**Implementation**: Use `CryptoSwift` or similar library for bcrypt (Swift Package Manager).

### Decision 5: LocalAuthentication for Biometric Verification
**Choice**: Require biometric enrollment during account creation, use `LAPolicy.deviceOwnerAuthenticationWithBiometrics`.

**Rationale**:
- Native iOS framework with Face ID/Touch ID support
- Enhances security beyond password-only authentication
- Required for HIPAA-grade access control (multi-factor authentication)
- Improves UX (users prefer biometric over password entry)
- Graceful fallback to password if biometrics unavailable

**Biometric Flow**:
1. User completes email/password/name entry
2. Check biometric availability with `LAContext.canEvaluatePolicy()`
3. If available, prompt biometric enrollment with clinical-appropriate messaging
4. Store enrollment status in keychain (`biometric-enrollment` flag)
5. On subsequent logins, require biometric + password (or password-only fallback)

### Decision 6: 6-Digit Passcode as Biometric Alternative
**Choice**: Offer 6-digit passcode as alternative authentication method for users who cannot or prefer not to use biometric authentication.

**Rationale**:
- Accessibility requirement: Not all users can use Face ID/Touch ID (physical disabilities, medical conditions)
- User preference: Some users prefer PIN-based authentication for speed or privacy
- Healthcare context: Caregivers may need to access patient accounts with permission
- Simpler than complex passwords for quick authentication
- Still provides adequate security with device-level encryption and session timeout

**Passcode Requirements**:
- Exactly 6 numeric digits (consistent with iOS passcode patterns)
- Cannot be sequential (123456, 654321) or repeated (111111, 000000)
- Stored using same bcrypt + encryption as passwords
- Optional: rate limiting after 5 failed attempts (delays or lockout)

**User Flow**:
1. During registration: "Choose authentication method: Face ID/Touch ID or 6-Digit Passcode"
2. If passcode chosen: Prompt for 6-digit entry, confirm entry
3. Store passcode choice flag in keychain
4. On login: Show appropriate authentication method based on user choice
5. Allow changing authentication method in settings (future)

**Alternatives considered**:
- 4-digit PIN: Too weak for healthcare security standards
- Stronger password requirement (16+ chars): Too burdensome for frequent authentication
- Biometric-only: Excludes users with disabilities or incompatible devices

### Decision 7: MVVM Architecture with Repository Pattern
**Choice**: Use MVVM (Model-View-ViewModel) with Repository pattern for data access.

**Rationale**:
- Separates business logic (ViewModel) from UI (View) for testability
- Repository abstracts Core Data and encryption complexity
- Dependency injection enables unit testing without Core Data stack
- Aligns with SwiftUI reactive programming model
- Scalable for future backend integration (swap Repository implementation)

**Architecture**:
```
View (SignUpView)
  ↓ publishes user input
ViewModel (AuthenticationViewModel)
  ↓ validates input, calls repository
Repository (UserRepository protocol)
  ↓ encrypts data, interacts with Core Data
Persistence (PersistenceController + EncryptionManager)
```

### Decision 8: Audit Logging for HIPAA Compliance
**Choice**: Implement local audit log with encrypted JSON entries stored in Core Data.

**Rationale**:
- HIPAA requires audit trail of authentication events (45 CFR § 164.312(b))
- Local logging sufficient for MVP (no centralized logging service)
- Encrypted audit entries protect PHI in logs
- Queryable for compliance audits and security investigations

**Logged Events**:
- Account creation (timestamp, user ID, success/failure)
- Login attempts (timestamp, user ID, method, success/failure, failure reason)
- Biometric enrollment (timestamp, user ID)
- Data access (future: when PHI is accessed)
- Session termination (logout, timeout)

**Audit Log Schema**:
```swift
class AuditLogEntry: NSManagedObject {
    @NSManaged var id: UUID
    @NSManaged var timestamp: Date
    @NSManaged var eventType: String  // "account_created", "login_success", etc.
    @NSManaged var userId: UUID?
    @NSManaged var encryptedDetails: Data  // JSON with event-specific data
    @NSManaged var deviceId: String  // UUID identifying device
}
```

## Risks / Trade-offs

### Risk 1: User Forgets Password (No Reset Flow in MVP)
**Impact**: User permanently locked out of account (local-only, no backend recovery).

**Mitigation**:
- Enforce biometric enrollment (reduces password-only dependency)
- Display clear warning during registration: "Store password securely - account recovery requires contacting support"
- Future: Add backend-based password reset flow

### Risk 2: Device Loss/Theft with Unlocked App
**Impact**: Unauthorized access to PHI if device stolen while app unlocked.

**Mitigation**:
- Implement session timeout (5 minutes of inactivity)
- Require biometric re-authentication for sensitive operations
- Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` (data inaccessible when locked)
- Future: Add remote wipe capability via backend

### Risk 3: Biometric Spoofing (False Acceptance)
**Impact**: Attacker bypasses biometric authentication with spoofed fingerprint/face.

**Mitigation**:
- iOS LocalAuthentication uses Secure Enclave (hardware-backed, difficult to spoof)
- Biometric + password requirement for critical operations (future)
- Audit logging detects suspicious authentication patterns
- Accept low FAR (False Acceptance Rate) of Face ID (~1 in 1,000,000)

### Risk 4: Core Data Encryption Key Extraction
**Impact**: Attacker with physical device access extracts keychain, decrypts data.

**Mitigation**:
- Keychain uses hardware-backed encryption (Secure Enclave on newer devices)
- `WhenUnlockedThisDeviceOnly` requires device passcode to access keychain
- Field-level encryption adds defense-in-depth (even if keychain compromised, attacker needs per-field decryption)
- Acceptable residual risk for MVP (jailbroken devices out of scope)

### Trade-off 1: User Experience vs. Security (Complex Password Requirements)
**Decision**: Enforce strong password requirements (12+ chars, mixed case, numbers, symbols).

**Rationale**: HIPAA compliance and PHI protection outweigh UX friction. Biometric auth reduces password entry frequency.

### Trade-off 2: Local-Only Storage vs. Backend Integration
**Decision**: Local-only for MVP, design for future backend migration.

**Rationale**:
- Faster MVP delivery (no backend infrastructure)
- Reduced initial compliance burden (no server-side HIPAA certification)
- Repository pattern enables backend swap without UI changes
- Accept limitation: No multi-device sync, account recovery, or cloud backup

## Migration Plan

### Phase 1: MVP (Local-Only)
1. Implement Core Data encrypted storage
2. Build authentication UI (SignUpView, LoginView)
3. Add encryption, keychain, biometric layers
4. Implement audit logging
5. Complete unit and UI tests
6. Security audit and penetration testing

### Phase 2: Backend Integration (Future)
1. Design backend API (user registration, authentication, session management)
2. Implement UserRepository backend adapter
3. Add cloud sync for user profiles
4. Implement password reset flow (email-based OTP)
5. Migrate audit logs to centralized logging service
6. Add multi-device session management

### Rollback Plan
Since MVP is local-only with no server dependencies:
- Revert code changes via git
- Core Data migration: Delete User entity, restore Item entity
- Keychain cleanup: Remove encryption keys on app uninstall (automatic)
- No data migration needed (fresh installs only in MVP)

## Open Questions

1. ✅ **Password reset for local-only storage**: Decided - No reset in MVP, display warning, require biometric as backup.

2. ✅ **Biometric fallback behavior**: Decided - If biometric unavailable/fails, fallback to password-only authentication or 6-digit passcode.

3. ✅ **Session timeout duration**: Decided - 5 minutes of inactivity triggers logout, requires re-authentication.

4. ✅ **Email uniqueness validation**: Decided - NOT implemented in MVP (local-only, single user per device assumption). Future PR will add unique constraint when multi-user support is needed.

5. ✅ **Account deletion**: Decided - NOT implemented in MVP (HIPAA retention requirements, out of scope). Future PR will add "request account deletion" flow with compliance checks.

6. ✅ **Accessibility for biometric enrollment**: Decided - Biometric is optional. Users can choose 6-digit passcode as alternative authentication method if biometrics unavailable or declined.

7. ✅ **Localization**: Decided - English-only for MVP. Future PR will add localization support (Spanish, etc.) using Localizable.strings infrastructure.

## Future Enhancements (Separate PRs)

The following features are explicitly OUT OF SCOPE for this MVP but documented for future implementation:

### Future PR #1: Email Uniqueness Constraint
**Why Deferred**: MVP assumes single user per device (local-only storage). Email uniqueness is not critical without multi-user or backend sync.

**Future Implementation**:
- Add Core Data unique constraint on `User.email` attribute
- Implement validation in `UserRepository.createUser()` to check for duplicates
- Return user-friendly error: "An account with this email already exists"
- Update unit tests to verify uniqueness constraint enforcement
- Consider: Backend email verification via OTP when cloud sync is added

**Estimated Effort**: Small (1-2 days)

### Future PR #2: Account Deletion Flow
**Why Deferred**: HIPAA requires data retention for medical records (typically 7+ years). Account deletion requires compliance review and physician approval workflow, which is out of scope for authentication MVP.

**Future Implementation**:
- Add "Request Account Deletion" button in Settings
- Implement compliance check: Verify no active treatment plans or pending assessments
- Require physician approval for accounts with medical history
- Add deletion confirmation with warning about HIPAA retention requirements
- Implement soft delete (mark account as `deleted`, retain encrypted data for retention period)
- Add scheduled job to permanently delete accounts after retention period expires
- Update audit log to record deletion requests and approvals

**Estimated Effort**: Medium (5-7 days, requires compliance review)

**Dependencies**: Backend integration, physician dashboard, compliance workflow

### Future PR #3: Localization and Internationalization (i18n)
**Why Deferred**: English-only sufficient for MVP launch. Localization adds complexity for translations, testing, and maintenance without immediate user benefit.

**Future Implementation**:
- Create `Localizable.strings` files for target languages (Spanish, Mandarin, etc.)
- Extract all user-facing strings from code into localization keys
- Translate authentication flows, error messages, and biometric prompts
- Test UI layout with longer translated strings (German, etc.)
- Add language selection in Settings (or use iOS system language)
- Update accessibility labels and VoiceOver hints for translated content
- Ensure HIPAA compliance documentation is available in target languages

**Estimated Effort**: Medium-Large (1-2 weeks per language, including translation and testing)

**Target Languages** (priority order based on US demographics):
1. Spanish (40+ million speakers in US)
2. Mandarin Chinese
3. French (Louisiana, Canadian patients)
4. Vietnamese
5. Korean

### Future PR #4: Password Reset Flow (Requires Backend)
**Why Deferred**: Local-only MVP has no backend for email-based password reset. Users must contact support or create new account if password forgotten.

**Future Implementation**:
- Backend API endpoint for password reset request
- Email-based OTP (One-Time Password) delivery
- Secure token generation and expiration (15-minute validity)
- Password reset form with OTP verification
- Update `UserRepository` to support password changes
- Audit log entries for password reset events
- Rate limiting to prevent abuse (max 5 reset requests per hour)

**Estimated Effort**: Medium (4-5 days)

**Dependencies**: Backend API, email service integration, HIPAA-compliant email provider

### Future PR #5: Multi-Device Session Management
**Why Deferred**: MVP is local-only with single device per user. Multi-device support requires cloud sync and backend session coordination.

**Future Implementation**:
- Backend session store (Redis or database)
- Device registration and management (list of authorized devices)
- Push notification for suspicious login attempts
- Remote logout capability (invalidate sessions on all devices)
- "Active Sessions" view showing logged-in devices
- Concurrent session limits (e.g., max 3 devices)

**Estimated Effort**: Large (2-3 weeks)

**Dependencies**: Backend infrastructure, push notification service

### Future PR #6: Advanced Authentication Options
**Why Deferred**: MVP covers core authentication needs. Advanced options add complexity without immediate value.

**Future Implementation Options**:
- SMS-based two-factor authentication (2FA)
- Authenticator app support (TOTP: Time-based One-Time Password)
- Hardware security key support (YubiKey, etc.)
- Adaptive authentication (risk-based challenges)
- Single Sign-On (SSO) for enterprise healthcare systems

**Estimated Effort**: Variable (1-3 weeks per feature)

**Dependencies**: Backend integration, third-party authentication services

### Future PR #7: Biometric Re-enrollment and Recovery
**Why Deferred**: iOS handles most biometric changes automatically. Edge cases are rare and can be handled via support in MVP.

**Future Implementation**:
- Detect biometric changes (new face/fingerprint enrolled on device)
- Prompt user to re-verify identity with password before accepting new biometric
- Biometric recovery flow if Face ID/Touch ID becomes unavailable
- Migration from biometric to passcode (and vice versa) in Settings

**Estimated Effort**: Small-Medium (3-5 days)

## MVP Scope Summary

**INCLUDED in MVP**:
- ✅ Email/password registration with strong password requirements
- ✅ Full name collection (minimal PII)
- ✅ Biometric authentication (Face ID/Touch ID) - optional
- ✅ 6-digit passcode as biometric alternative
- ✅ HIPAA-compliant encryption (AES-256-GCM, bcrypt)
- ✅ Secure keychain storage
- ✅ Session management (5-minute timeout)
- ✅ Audit logging (encrypted, local)
- ✅ Accessibility support (VoiceOver, Dynamic Type)
- ✅ Error handling without crashes
- ✅ Local-only storage (no backend)
- ✅ English-only UI

**EXCLUDED from MVP** (future PRs):
- ❌ Email uniqueness constraint (not needed for single user per device)
- ❌ Account deletion (requires HIPAA compliance workflow)
- ❌ Localization (English-only MVP)
- ❌ Password reset (requires backend)
- ❌ Multi-device sync (requires backend)
- ❌ Email verification via OTP (requires backend)
- ❌ SMS 2FA, authenticator apps (advanced auth)
- ❌ Social login (Apple Sign In, Google)
