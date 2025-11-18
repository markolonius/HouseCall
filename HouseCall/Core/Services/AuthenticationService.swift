//
//  AuthenticationService.swift
//  HouseCall
//
//  High-level authentication service with session management
//  Implements 5-minute session timeout for HIPAA compliance
//

import Foundation
import Combine

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
    static let shared = AuthenticationService()

    @Published var currentSession: UserSession?
    @Published var isAuthenticated: Bool = false

    private let userRepository: UserRepositoryProtocol
    private let keychainManager: KeychainManager
    private let biometricAuthManager: BiometricAuthManager
    private let auditLogger: AuditLogger

    private var sessionTimeoutTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(
        userRepository: UserRepositoryProtocol = CoreDataUserRepository(),
        keychainManager: KeychainManager = .shared,
        biometricAuthManager: BiometricAuthManager = .shared,
        auditLogger: AuditLogger = .shared
    ) {
        self.userRepository = userRepository
        self.keychainManager = keychainManager
        self.biometricAuthManager = biometricAuthManager
        self.auditLogger = auditLogger

        // Restore session on init
        restoreSession()

        // Start session monitoring
        startSessionMonitoring()
    }

    // MARK: - Registration

    /// Registers a new user
    @MainActor
    func register(
        email: String,
        password: String?,
        passcode: String?,
        fullName: String,
        authMethod: AuthMethod
    ) async throws -> User {
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

    // MARK: - Login

    /// Logs in a user with credentials
    @MainActor
    func login(
        email: String,
        credential: String,
        authMethod: AuthMethod,
        useBiometric: Bool = false
    ) async throws -> User {
        // If biometric auth is requested, perform it first
        if useBiometric && authMethod == .biometric {
            let reason = BiometricAuthManager.createAuthenticationReason(for: "login")
            let result = await biometricAuthManager.authenticate(reason: reason)

            guard result.success else {
                let errorMsg = result.error?.errorDescription ?? "Unknown error"
                throw AuthenticationError.biometricAuthFailed(errorMsg)
            }
        }

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

        // Clear keychain
        try keychainManager.deleteSessionToken()

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

        currentSession = session
        isAuthenticated = true

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
                try? await handleSessionTimeout()
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
        currentSession?.updateActivity()
        // Reset timeout timer
        startSessionTimeoutTimer()
    }

    /// Restores session from keychain if available
    private func restoreSession() {
        guard let sessionToken = try? keychainManager.retrieveSessionToken(),
              let authMethodString = try? keychainManager.retrieveAuthMethod(),
              let authMethod = AuthMethod(rawValue: authMethodString) else {
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
    @MainActor
    private func handleSessionTimeout() async {
        guard let session = currentSession else {
            return
        }

        // Log timeout event
        try? auditLogger.logSessionTimeout(userId: session.userId)

        // Invalidate session
        try? invalidateSession()
        try? keychainManager.deleteSessionToken()
    }

    /// Starts monitoring for app lifecycle events
    private func startSessionMonitoring() {
        // Monitor app going to background
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                // Record last activity time when app goes to background
                self?.currentSession?.updateActivity()
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
}
