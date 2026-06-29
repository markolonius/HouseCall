//
//  AuthenticationService.swift
//  HouseCall
//
//  High-level authentication service with session management
//  Implements 5-minute session timeout for HIPAA compliance
//

import Foundation
import Combine
import UIKit

/// Authentication service errors
enum AuthenticationError: LocalizedError {
    case registrationFailed(String)
    case loginFailed(String)
    case sessionCreationFailed
    case sessionValidationFailed
    case noActiveSession
    case biometricAuthFailed(String)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let reason):
            return "Registration failed: \(reason)"
        case .loginFailed(let reason):
            return "Login failed: \(reason)"
        case .sessionCreationFailed:
            return "Failed to create user session"
        case .sessionValidationFailed:
            return "Session validation failed"
        case .noActiveSession:
            return "No active user session"
        case .biometricAuthFailed(let reason):
            return "Biometric authentication failed: \(reason)"
        }
    }
}

/// Session state for tracking user sessions
struct UserSession {
    let userId: UUID
    let sessionToken: UUID
    let createdAt: Date
    var lastActivityAt: Date
    let authMethod: AuthMethod

    var isExpired: Bool {
        let timeoutInterval: TimeInterval = 5 * 60 // 5 minutes
        return Date().timeIntervalSince(lastActivityAt) > timeoutInterval
    }

    mutating func updateActivity() {
        lastActivityAt = Date()
    }
}

/// High-level authentication service
class AuthenticationService: ObservableObject {

    // `shared` reads Core API config at first access.  When both
    // `CoreAPIBaseURL` and `CoreAPITenantID` are set in the xcconfig,
    // the singleton is cloud-enabled; otherwise it is local-only.
    // Tests that construct `AuthenticationService(...)` directly are
    // unaffected — the memberwise init defaults remain `nil`.
    static let shared: AuthenticationService = makeShared()

    /// Production factory.  Reads build-time config via `CoreAPIConfig`
    /// and returns a cloud-enabled instance when both the base URL and the
    /// tenant ID are present, or a local-only instance when either is absent.
    ///
    /// Tests should NOT call this method; inject deps via the memberwise
    /// `init(...)` instead to keep tests hermetic.
    private static func makeShared() -> AuthenticationService {
        guard
            let urlString = CoreAPIConfig.baseURLString(),
            let baseURL = URL(string: urlString),
            let tenantId = CoreAPIConfig.tenantID(),
            let client = try? CoreAPIAuthClient(baseURL: baseURL)
        else {
            // Config absent or URL invalid — local-only, zero behaviour change.
            return AuthenticationService()
        }
        return AuthenticationService(
            coreAuthClient: client,
            coreAPITenantId: tenantId
        )
    }

    // MARK: - Internal factory for test-time config-gating verification
    //
    // Allows tests to exercise the config-gating logic (non-nil client vs. nil)
    // without touching the real singleton or `Bundle.main`.
    // Production code MUST use `shared`; only HouseCallTests uses this entry point.

    /// Returns an `AuthenticationService` wired with cloud deps when both
    /// `urlString` and `tenantId` are non-nil and `urlString` is a valid,
    /// TLS-compliant URL; returns a local-only instance otherwise.
    ///
    /// - Parameters:
    ///   - urlString: The raw base URL string (mirrors `CoreAPIConfig.baseURLString()`).
    ///   - tenantId:  The tenant ID string (mirrors `CoreAPIConfig.tenantID()`).
    ///
    /// This method is intentionally test-only (DEBUG) so it cannot be reached
    /// from production code or a Release binary.  It is NOT part of the public API.
    #if DEBUG
    static func _testMakeInstance(
        coreAPIBaseURLString urlString: String?,
        tenantId: String?
    ) -> AuthenticationService {
        guard
            let urlString,
            let baseURL = URL(string: urlString),
            let tenantId,
            let client = try? CoreAPIAuthClient(baseURL: baseURL)
        else {
            return AuthenticationService()
        }
        return AuthenticationService(
            coreAuthClient: client,
            coreAPITenantId: tenantId
        )
    }
    #endif

    @Published var currentSession: UserSession?
    @Published var isAuthenticated: Bool = false

    private let userRepository: UserRepositoryProtocol
    private let keychainManager: KeychainManager
    private let biometricAuthManager: BiometricAuthManager
    private let auditLogger: AuditLogger

    // MARK: - Cloud Auth (Task 3.1)

    /// Optional Core API auth client.  When non-nil (together with
    /// `coreAPITenantId`), registration and login route through Core API.
    /// `nil` preserves the original local-only behaviour — no existing call
    /// sites or tests are affected.  Production wiring is finalised in phase 5.
    private let coreAuthClient: CoreAPIAuthClientProtocol?

    /// Tenant identifier passed to Core API auth calls.  Must be non-nil
    /// alongside `coreAuthClient` for cloud auth to activate.
    private let coreAPITenantId: String?

    /// Injected after login so timeout and logout both stop the WebSocket
    /// subscription and prevent PHI from being delivered to an expired session.
    /// Set this to the active `CloudSyncCoordinator` once the coordinator is
    /// started; set it back to `nil` after `stop()` is called.
    weak var syncCoordinator: CloudSyncCoordinator?

    private var sessionTimeoutTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(
        userRepository: UserRepositoryProtocol = CoreDataUserRepository(),
        keychainManager: KeychainManager = .shared,
        biometricAuthManager: BiometricAuthManager = .shared,
        auditLogger: AuditLogger = .shared,
        coreAuthClient: CoreAPIAuthClientProtocol? = nil,
        coreAPITenantId: String? = nil
    ) {
        self.userRepository = userRepository
        self.keychainManager = keychainManager
        self.biometricAuthManager = biometricAuthManager
        self.auditLogger = auditLogger
        self.coreAuthClient = coreAuthClient
        self.coreAPITenantId = coreAPITenantId

        // Restore session on init
        restoreSession()

        // Start session monitoring
        startSessionMonitoring()
    }

    // MARK: - Registration

    /// Registers a new user.
    ///
    /// **Cloud path** (when `coreAuthClient` and `coreAPITenantId` are both set):
    /// 1. `POST /api/auth/register` → `{token, patientId}`.
    /// 2. Create the local cache user keyed by `patientId` so the HKDF salt
    ///    equals the server-canonical identity (encryption-identity continuity).
    /// 3. Store the JWT via `storeCoreAPIJWT(_:)`.
    /// 4. Start the session as usual.
    ///
    /// Error mapping (cloud path only):
    /// - 409 conflict → `registrationFailed("Email already registered")`
    /// - Network unreachable → `registrationFailed("Registration requires…")`
    /// - 401 → `registrationFailed("Registration unauthorised")`
    ///
    /// **Local path** (nil cloud deps): unchanged from the original behaviour.
    @MainActor
    func register(
        email: String,
        password: String?,
        passcode: String?,
        fullName: String,
        authMethod: AuthMethod
    ) async throws -> User {
        // Cloud-enabled path
        if let authClient = coreAuthClient, let tenantId = coreAPITenantId {
            return try await registerViaCloudAPI(
                authClient: authClient,
                tenantId: tenantId,
                email: email,
                password: password,
                passcode: passcode,
                fullName: fullName,
                authMethod: authMethod
            )
        }

        // Local-only path (unchanged)
        do {
            let user = try userRepository.createUser(
                email: email,
                password: password,
                passcode: passcode,
                fullName: fullName,
                authMethod: authMethod
            )

            // Create session for newly registered user
            try await createSession(for: user, authMethod: authMethod)

            return user
        } catch {
            throw AuthenticationError.registrationFailed(error.localizedDescription)
        }
    }

    /// Cloud registration flow.  Separated from the public `register` method so
    /// the control flow is easy to read and the local path has zero added
    /// indentation.
    @MainActor
    private func registerViaCloudAPI(
        authClient: CoreAPIAuthClientProtocol,
        tenantId: String,
        email: String,
        password: String?,
        passcode: String?,
        fullName: String,
        authMethod: AuthMethod
    ) async throws -> User {
        // Step 1: Obtain the server-canonical patient UUID and JWT.
        // Registration requires connectivity — offline is a hard failure here.
        // (Offline login fallback is handled in task 4.1.)
        let authResult: CoreAPIAuthResult
        do {
            // Core API register requires a password credential.
            let pw = password ?? ""
            // Patient state (USPS code) gates physician state-licensing; supplied
            // via build config for the MVP, omitted (→ "--") when unconfigured.
            authResult = try await authClient.register(
                tenantId: tenantId,
                email: email,
                password: pw,
                state: CoreAPIConfig.patientState()
            )
        } catch let syncErr as SyncError {
            switch syncErr {
            case .conflict:
                throw AuthenticationError.registrationFailed("Email already registered")
            case .unauthorized:
                throw AuthenticationError.registrationFailed("Registration unauthorised")
            case .offline:
                // Do not embed the raw offline reason — system error strings can
                // carry sensitive context (matches SyncError.offline.errorDescription).
                throw AuthenticationError.registrationFailed(
                    "Registration requires network connectivity"
                )
            default:
                throw AuthenticationError.registrationFailed(syncErr.localizedDescription ?? "Server error")
            }
        } catch {
            throw AuthenticationError.registrationFailed(error.localizedDescription)
        }

        // Step 2: Parse the server-canonical patient UUID.
        guard let patientId = UUID(uuidString: authResult.patientId) else {
            throw AuthenticationError.registrationFailed("Invalid patient id from server")
        }

        // Step 3: Create the local cache user keyed by patientId so that
        // EncryptionManager.getDerivedKey(for: user.id) uses the canonical salt.
        let user: User
        do {
            user = try userRepository.createUser(
                email: email,
                password: password,
                passcode: passcode,
                fullName: fullName,
                authMethod: authMethod,
                id: patientId
            )
        } catch {
            throw AuthenticationError.registrationFailed(error.localizedDescription)
        }

        // Step 4: Persist the JWT for subsequent authenticated Core API calls.
        // Errors here are non-fatal for the registration itself but unusual —
        // cloud sync will remain inactive until the next login refreshes the JWT.
        try? storeCoreAPIJWT(authResult.token)

        // Step 5: Start the local session (encryption unlocks via user.id == patientId).
        try await createSession(for: user, authMethod: authMethod)

        return user
    }

    // MARK: - Login

    /// Logs in a user with credentials.
    ///
    /// **Cloud path** (when `coreAuthClient` and `coreAPITenantId` are both set):
    /// 1. `POST /api/auth/login` → `{token, patientId}`.
    /// 2. Ensure the local cache user for `patientId` exists; create one keyed by
    ///    `patientId` if missing (first login on this device).
    /// 3. Store the JWT via `storeCoreAPIJWT(_:)`.
    /// 4. Start the session — encryption unlocks for `user.id == patientId`.
    ///
    /// Error mapping (cloud path only):
    /// - 401 (unauthorized) → `loginFailed(...)`. Core API is authoritative; no fallback.
    /// - Network unreachable → `loginFailed(...)` for now (task 4.1 will add offline fallback).
    ///
    /// **Local path** (nil cloud deps): unchanged from the original behaviour.
    @MainActor
    func login(
        email: String,
        credential: String,
        authMethod: AuthMethod,
        useBiometric: Bool = false
    ) async throws -> User {
        // Biometric pre-check (preserved from original behaviour).
        // Runs regardless of cloud/local path: biometric gates device-local session
        // access; it does not replace the Core API credential check.
        if useBiometric && authMethod == .biometric {
            let reason = BiometricAuthManager.createAuthenticationReason(for: "login")
            let result = await biometricAuthManager.authenticate(reason: reason)

            guard result.success else {
                let errorMsg = result.error?.errorDescription ?? "Unknown error"
                throw AuthenticationError.biometricAuthFailed(errorMsg)
            }
        }

        // Cloud-enabled path
        if let authClient = coreAuthClient, let tenantId = coreAPITenantId {
            return try await loginViaCloudAPI(
                authClient: authClient,
                tenantId: tenantId,
                email: email,
                credential: credential,
                authMethod: authMethod
            )
        }

        // Local-only path (unchanged)
        do {
            let user = try userRepository.authenticateUser(
                email: email,
                credential: credential,
                authMethod: authMethod
            )

            try await createSession(for: user, authMethod: authMethod)

            return user
        } catch {
            throw AuthenticationError.loginFailed(error.localizedDescription)
        }
    }

    /// Cloud login flow.  Separated from the public `login` method so the
    /// control flow is easy to read and the local path has zero added indentation.
    @MainActor
    private func loginViaCloudAPI(
        authClient: CoreAPIAuthClientProtocol,
        tenantId: String,
        email: String,
        credential: String,
        authMethod: AuthMethod
    ) async throws -> User {
        // Step 1: Authenticate against Core API (Core API is authoritative).
        let authResult: CoreAPIAuthResult
        do {
            authResult = try await authClient.login(
                tenantId: tenantId,
                email: email,
                password: credential
            )
        } catch let syncErr as SyncError {
            switch syncErr {
            case .unauthorized:
                // Core API explicitly rejected the credentials — do NOT fall back
                // to a local credential check; Core API is the single source of truth.
                throw AuthenticationError.loginFailed("Invalid credentials")
            case .offline:
                // Core API is unreachable (network failure / timeout) — attempt the
                // cached local-credential check so a previously-authenticated patient
                // can open their encrypted local record for offline use.
                //
                // IMPORTANT: this fallback applies ONLY to .offline (transport
                // unreachable).  .unauthorized (server rejected the credentials)
                // stays above and NEVER reaches this branch — Core API is the
                // single source of truth for credential validity.
                //
                // No JWT is obtained; cloud sync stays inactive until a subsequent
                // online login succeeds and a fresh token is stored.
                do {
                    let localUser = try userRepository.authenticateUser(
                        email: email,
                        credential: credential,
                        authMethod: authMethod
                    )
                    // Local check succeeded: start a session from the cached record.
                    try await createSession(for: localUser, authMethod: authMethod)
                    return localUser
                } catch {
                    // No cached user for this email, or credential mismatch —
                    // offline access cannot be granted without a valid local record.
                    throw AuthenticationError.loginFailed(
                        "Unable to reach the server. Please check your connection."
                    )
                }
            default:
                throw AuthenticationError.loginFailed(syncErr.localizedDescription ?? "Server error")
            }
        } catch {
            throw AuthenticationError.loginFailed(error.localizedDescription)
        }

        // Step 2: Parse the server-canonical patient UUID.
        guard let patientId = UUID(uuidString: authResult.patientId) else {
            throw AuthenticationError.loginFailed("Invalid patient id from server")
        }

        // Step 3: Ensure the local cache user exists for the canonical patientId.
        // On first login on this device the record may not exist yet (e.g., the
        // patient registered on another device or the local store was cleared).
        // Creating it here keyed by patientId keeps the HKDF salt stable and equal
        // to the server-canonical identity — encryption-identity continuity.
        let user: User
        if let existingUser = userRepository.findUser(by: patientId) {
            user = existingUser
        } else {
            do {
                user = try userRepository.createUser(
                    email: email,
                    password: authMethod == .password ? credential : nil,
                    passcode: authMethod == .passcode ? credential : nil,
                    fullName: "",   // Not known at login; profile sync is future work (not in this change)
                    authMethod: authMethod,
                    id: patientId
                )
            } catch {
                throw AuthenticationError.loginFailed(error.localizedDescription)
            }
        }

        // Step 4: Persist the JWT for subsequent authenticated Core API calls.
        try? storeCoreAPIJWT(authResult.token)

        // Step 5: Start the local session (encryption unlocks via user.id == patientId).
        try await createSession(for: user, authMethod: authMethod)

        return user
    }

    /// Logs in with biometric authentication only
    @MainActor
    func loginWithBiometric(email: String) async throws -> User {
        // Perform biometric authentication
        let reason = BiometricAuthManager.createAuthenticationReason(for: "login")
        let result = await biometricAuthManager.authenticate(reason: reason)

        guard result.success else {
            let errorMsg = result.error?.errorDescription ?? "Unknown error"
            throw AuthenticationError.biometricAuthFailed(errorMsg)
        }

        // Find user
        guard let user = userRepository.findUser(by: email) else {
            throw AuthenticationError.loginFailed("User not found")
        }

        // Verify user has biometric enabled
        guard user.authMethod == AuthMethod.biometric.rawValue else {
            throw AuthenticationError.loginFailed("Biometric authentication not enabled for this account")
        }

        try await createSession(for: user, authMethod: .biometric)

        return user
    }

    // MARK: - Logout

    /// Logs out the current user
    @MainActor
    func logout() async throws {
        guard let session = currentSession else {
            return
        }

        // Log logout event
        try? auditLogger.log(
            event: .logoutSuccess,
            userId: session.userId,
            message: "User logged out"
        )

        // Clear session
        try invalidateSession()

        // Clear keychain — session token and Core API JWT
        try keychainManager.deleteSessionToken()
        clearCoreAPIJWT()

        // Evict in-memory encryption keys so a logged-out session retains no
        // key material. The Keychain master key is preserved so at-rest PHI
        // remains decryptable after the next login.
        EncryptionManager.shared.clearCachedKeys()

        // Stop cloud sync so the WebSocket subscription is cancelled and no
        // further PHI events can be delivered or persisted after logout.
        syncCoordinator?.stop()
        syncCoordinator = nil

        // Update state
        currentSession = nil
        isAuthenticated = false
    }

    // MARK: - Session Management

    /// Creates a new session for a user
    @MainActor
    private func createSession(for user: User, authMethod: AuthMethod) async throws {
        guard let userId = user.id else {
            throw AuthenticationError.sessionCreationFailed
        }

        let sessionToken = UUID()

        // Save session token to keychain
        do {
            try keychainManager.saveSessionToken(sessionToken)
        } catch {
            throw AuthenticationError.sessionCreationFailed
        }

        // Save auth method preference
        try? keychainManager.saveAuthMethod(authMethod.rawValue)

        // Create session object
        let session = UserSession(
            userId: userId,
            sessionToken: sessionToken,
            createdAt: Date(),
            lastActivityAt: Date(),
            authMethod: authMethod
        )

        // Defer @Published property updates to avoid "Publishing changes from within view updates" error
        // Even though we're on @MainActor, we need to defer to the next run loop cycle
        // to ensure updates happen outside the current view update cycle
        Task { @MainActor in
            currentSession = session
            isAuthenticated = true
        }

        // Log session creation
        try? auditLogger.log(
            event: .sessionCreated,
            userId: userId,
            message: "User session created"
        )

        // Start session timeout monitoring
        startSessionTimeoutTimer()
    }

    /// Validates the current session
    func validateSession() -> User? {
        guard let session = currentSession else {
            return nil
        }

        // Check if session is expired
        if session.isExpired {
            Task { @MainActor in
                await handleSessionTimeout()
            }
            return nil
        }

        // Update activity timestamp
        updateSessionActivity()

        // Get user
        return userRepository.findUser(by: session.userId)
    }

    /// Invalidates the current session
    func invalidateSession() throws {
        currentSession = nil
        isAuthenticated = false
        sessionTimeoutTimer?.invalidate()
        sessionTimeoutTimer = nil
    }

    /// Updates session activity timestamp
    func updateSessionActivity() {
        guard var session = currentSession else { return }
        
        // Defer the update to avoid "Publishing changes from within view updates" warning
        // This ensures the update happens outside the current view update cycle
        Task { @MainActor in
            session.updateActivity()
            self.currentSession = session
            // Reset timeout timer
            self.startSessionTimeoutTimer()
        }
    }

    /// Restores session from keychain if available
    private func restoreSession() {
        guard let _ = try? keychainManager.retrieveSessionToken(),
              let authMethodString = try? keychainManager.retrieveAuthMethod(),
              let _ = AuthMethod(rawValue: authMethodString) else {
            return
        }

        // Note: In a full implementation, we'd also store userId in keychain
        // For now, this is a placeholder for session restoration logic
        // A complete implementation would require additional keychain storage
    }

    // MARK: - Session Timeout

    /// Starts the session timeout timer
    private func startSessionTimeoutTimer() {
        sessionTimeoutTimer?.invalidate()

        sessionTimeoutTimer = Timer.scheduledTimer(
            withTimeInterval: 60, // Check every minute
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.checkSessionTimeout()
            }
        }
    }

    /// Checks if session has timed out
    @MainActor
    private func checkSessionTimeout() async {
        guard let session = currentSession, session.isExpired else {
            return
        }

        await handleSessionTimeout()
    }

    /// Handles session timeout
    ///
    /// Mirrors the explicit `logout()` teardown path:
    ///  - Invalidates the local session and deletes the session token.
    ///  - Clears the Core API JWT so it cannot be used after expiry.
    ///  - Stops the sync coordinator so the WebSocket subscription is cancelled
    ///    and no further recommendation PHI can be delivered or persisted.
    ///
    /// The JWT clear and coordinator stop run unconditionally so that the
    /// HIPAA teardown is always complete even if `currentSession` was already
    /// cleared by a racing logout.
    @MainActor
    private func handleSessionTimeout() async {
        // Log the timeout event while we still have the session reference.
        if let session = currentSession {
            try? auditLogger.logSessionTimeout(userId: session.userId)
        }

        // Invalidate session and remove both keychain tokens.
        try? invalidateSession()
        try? keychainManager.deleteSessionToken()
        clearCoreAPIJWT()

        // Evict in-memory encryption keys (Keychain master key preserved).
        EncryptionManager.shared.clearCachedKeys()

        // Stop cloud sync — cancel the WebSocket subscription and prevent any
        // in-flight recommendation.delivered events from persisting PHI.
        syncCoordinator?.stop()
        syncCoordinator = nil
    }

    /// Starts monitoring for app lifecycle events
    private func startSessionMonitoring() {
        // Monitor app going to background
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Record last activity time when app goes to background
                    guard var session = self?.currentSession else { return }
                    session.updateActivity()
                    self?.currentSession = session
                }
            }
            .store(in: &cancellables)

        // Monitor app coming to foreground
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    // Check if session expired while app was in background
                    await self?.checkSessionTimeout()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Core API JWT (Phase 6.3)

    /// Stores the Core API JWT in the Keychain so SyncClient can authenticate.
    ///
    /// Call this after a successful `POST /auth/login` to the Core API returns
    /// a JWT.  The token is stored under `KeychainManager.Keys.coreAPIJWT` and
    /// is never logged.
    ///
    /// - Parameter jwt: The short-lived HMAC-signed JWT returned by the Core API.
    /// - Throws: KeychainError if the Keychain write fails.
    func storeCoreAPIJWT(_ jwt: String) throws {
        try keychainManager.set(key: KeychainManager.Keys.coreAPIJWT, value: jwt)
    }

    /// Removes the Core API JWT from the Keychain.  Called on logout.
    func clearCoreAPIJWT() {
        try? keychainManager.delete(key: KeychainManager.Keys.coreAPIJWT)
    }

    // MARK: - User Information

    /// Gets the current authenticated user
    func getCurrentUser() -> User? {
        return validateSession()
    }

    /// Gets the current user's full name (decrypted)
    func getCurrentUserFullName() throws -> String? {
        guard let user = getCurrentUser(),
              let repository = userRepository as? CoreDataUserRepository else {
            return nil
        }

        return try repository.getDecryptedFullName(for: user)
    }

    // MARK: - Testing Support

    /// For unit-test use only.  Directly invokes the same timeout teardown
    /// path that fires when the 5-minute inactivity timer expires, so tests
    /// can assert that the Core API JWT is cleared and the sync coordinator
    /// is stopped without waiting for a real timer.
    @MainActor
    func _testSimulateSessionTimeout() async {
        await handleSessionTimeout()
    }

    /// `true` when this instance was constructed with a non-nil
    /// `coreAuthClient` AND a non-nil `coreAPITenantId`; `false` otherwise.
    ///
    /// For unit-test use only — confirms config-gating logic in
    /// `_testMakeInstance(coreAPIBaseURLString:tenantId:)`.
    #if DEBUG
    var _testIsCloudEnabled: Bool {
        coreAuthClient != nil && coreAPITenantId != nil
    }
    #endif
}
