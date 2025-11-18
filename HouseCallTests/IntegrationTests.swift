//
//  IntegrationTests.swift
//  HouseCallTests
//
//  Integration tests for cross-component functionality
//

import Testing
import CoreData
@testable import HouseCall

@Suite("Integration Tests")
struct IntegrationTests {

    // MARK: - Test Infrastructure

    func createTestComponents() -> (
        context: NSManagedObjectContext,
        encryptionManager: EncryptionManager,
        repository: CoreDataUserRepository,
        authService: AuthenticationService,
        auditLogger: AuditLogger
    ) {
        let container = NSPersistentContainer(name: "HouseCall")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }

        let context = container.viewContext
        let encryptionManager = EncryptionManager.shared
        let auditLogger = AuditLogger(context: context)
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: encryptionManager,
            passwordHasher: PasswordHasher.shared,
            auditLogger: auditLogger
        )
        let authService = AuthenticationService(
            userRepository: repository,
            keychainManager: KeychainManager.shared,
            biometricAuthManager: BiometricAuthManager.shared,
            auditLogger: auditLogger
        )

        return (context, encryptionManager, repository, authService, auditLogger)
    }

    // MARK: - Full Registration Flow

    @Test("Full registration flow (password auth)")
    @MainActor
    func testFullRegistrationFlowPassword() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let auditLogger = components.auditLogger

        // Register new user
        let user = try await authService.register(
            email: "newuser@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "New User",
            authMethod: .password
        )

        // Verify user created
        #expect(user.email == "newuser@example.com")
        #expect(user.authMethod == "password")
        #expect(user.encryptedPasswordHash != nil)

        // Verify session created
        #expect(authService.isAuthenticated == true)
        #expect(authService.currentSession != nil)

        // Verify audit log
        let auditEvents = try auditLogger.fetchUserEvents(userId: user.id!)
        let accountCreatedEvents = auditEvents.filter {
            $0.entry.eventType == "account_created"
        }
        let sessionCreatedEvents = auditEvents.filter {
            $0.entry.eventType == "session_created"
        }

        #expect(accountCreatedEvents.count >= 1)
        #expect(sessionCreatedEvents.count >= 1)

        // Cleanup
        try await authService.logout()
    }

    @Test("Full registration flow (passcode auth)")
    @MainActor
    func testFullRegistrationFlowPasscode() async throws {
        let components = createTestComponents()
        let authService = components.authService

        // Register with passcode
        let user = try await authService.register(
            email: "passcodeuser@example.com",
            password: nil,
            passcode: "135792",
            fullName: "Passcode User",
            authMethod: .passcode
        )

        #expect(user.authMethod == "passcode")
        #expect(user.encryptedPasscodeHash != nil)
        #expect(authService.isAuthenticated == true)

        try await authService.logout()
    }

    // MARK: - Full Login Flow

    @Test("Full login flow with password")
    @MainActor
    func testFullLoginFlowPassword() async throws {
        let components = createTestComponents()
        let repository = components.repository
        let authService = components.authService

        let email = "logintest@example.com"
        let password = "LoginPassword123!"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Login Test",
            authMethod: .password
        )

        // Login
        let user = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password,
            useBiometric: false
        )

        #expect(user.email == email)
        #expect(authService.isAuthenticated == true)
        #expect(authService.currentSession != nil)

        try await authService.logout()
    }

    @Test("Full login flow with passcode")
    @MainActor
    func testFullLoginFlowPasscode() async throws {
        let components = createTestComponents()
        let repository = components.repository
        let authService = components.authService

        let email = "passcodelogin@example.com"
        let passcode = "246801"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: nil,
            passcode: passcode,
            fullName: "Passcode Login",
            authMethod: .passcode
        )

        // Login
        let user = try await authService.login(
            email: email,
            credential: passcode,
            authMethod: .passcode,
            useBiometric: false
        )

        #expect(user.email == email)
        #expect(authService.isAuthenticated == true)

        try await authService.logout()
    }

    // MARK: - Session Management Integration

    @Test("Session persists across instances")
    @MainActor
    func testSessionPersistence() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let repository = components.repository

        // Create and login user
        let email = "sessiontest@example.com"
        let password = "SessionPassword123!"

        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Session Test",
            authMethod: .password
        )

        let user = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )

        let sessionToken = authService.currentSession?.sessionToken

        // Verify session exists
        #expect(sessionToken != nil)
        #expect(authService.isAuthenticated == true)

        // Validate session
        let validatedUser = authService.validateSession()
        #expect(validatedUser?.id == user.id)

        try await authService.logout()
    }

    @Test("Logout clears all state")
    @MainActor
    func testLogoutClearsState() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let repository = components.repository

        let email = "logouttest@example.com"
        let password = "LogoutPassword123!"

        // Create and login
        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Logout Test",
            authMethod: .password
        )

        _ = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )

        #expect(authService.isAuthenticated == true)

        // Logout
        try await authService.logout()

        // Verify state cleared
        #expect(authService.isAuthenticated == false)
        #expect(authService.currentSession == nil)
        #expect(authService.validateSession() == nil)
    }

    // MARK: - Error Handling Integration

    @Test("Failed login logs audit event")
    @MainActor
    func testFailedLoginLogsAudit() async throws {
        let components = createTestComponents()
        let repository = components.repository
        let authService = components.authService
        let auditLogger = components.auditLogger

        let email = "failedlogin@example.com"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: "CorrectPassword123!",
            passcode: nil,
            fullName: "Failed Login Test",
            authMethod: .password
        )

        // Attempt login with wrong password
        do {
            _ = try await authService.login(
                email: email,
                credential: "WrongPassword123!",
                authMethod: .password
            )
            #expect(Bool(false), "Login should have failed")
        } catch {
            // Expected to fail
        }

        // Check audit log
        let failureEvents = try auditLogger.fetchEvents(eventType: .loginFailure)
        #expect(failureEvents.count >= 1)
    }

    // MARK: - Encryption Integration

    @Test("End-to-end encryption of user data")
    func testEndToEndEncryption() throws {
        let components = createTestComponents()
        let repository = components.repository

        let fullName = "Encrypted User"
        let password = "EncryptedPassword123!"

        // Create user
        let user = try repository.createUser(
            email: "encrypted@example.com",
            password: password,
            passcode: nil,
            fullName: fullName,
            authMethod: .password
        )

        // Verify encrypted fields don't contain plaintext
        if let encryptedName = user.encryptedFullName {
            let encryptedString = String(data: encryptedName, encoding: .utf8) ?? ""
            #expect(!encryptedString.contains(fullName))
        }

        if let encryptedHash = user.encryptedPasswordHash {
            let hashString = String(data: encryptedHash, encoding: .utf8) ?? ""
            #expect(!hashString.contains(password))
        }

        // Verify decryption works
        let decryptedName = try repository.getDecryptedFullName(for: user)
        #expect(decryptedName == fullName)

        // Verify authentication works (password verification)
        let authenticatedUser = try repository.authenticateUser(
            email: "encrypted@example.com",
            credential: password,
            authMethod: .password
        )
        #expect(authenticatedUser.id == user.id)
    }

    // MARK: - Multi-Component Integration

    @Test("Complete user journey: register → login → logout")
    @MainActor
    func testCompleteUserJourney() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let auditLogger = components.auditLogger

        let email = "journey@example.com"
        let password = "JourneyPassword123!"

        // 1. Register
        let registeredUser = try await authService.register(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Journey User",
            authMethod: .password
        )

        #expect(authService.isAuthenticated == true)

        // 2. Logout
        try await authService.logout()
        #expect(authService.isAuthenticated == false)

        // 3. Login again
        let loggedInUser = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )

        #expect(loggedInUser.id == registeredUser.id)
        #expect(authService.isAuthenticated == true)

        // 4. Verify audit trail
        let auditEvents = try auditLogger.fetchUserEvents(userId: registeredUser.id!)
        #expect(auditEvents.count >= 4) // account_created, session_created, logout, login

        // 5. Final logout
        try await authService.logout()
    }

    // MARK: - Concurrent Operations

    @Test("Concurrent user registrations")
    @MainActor
    func testConcurrentRegistrations() async throws {
        let components = createTestComponents()
        let repository = components.repository

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    do {
                        _ = try repository.createUser(
                            email: "concurrent\(i)@example.com",
                            password: "ConcurrentPassword123!",
                            passcode: nil,
                            fullName: "Concurrent User \(i)",
                            authMethod: .password
                        )
                    } catch {
                        print("Concurrent registration error: \(error)")
                    }
                }
            }
        }

        // Verify all users created
        for i in 0..<5 {
            let user = repository.findUser(by: "concurrent\(i)@example.com")
            #expect(user != nil)
        }
    }

    // MARK: - Data Integrity

    @Test("Audit log completeness")
    @MainActor
    func testAuditLogCompleteness() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let auditLogger = components.auditLogger

        // Perform multiple operations
        let user = try await authService.register(
            email: "auditcomplete@example.com",
            password: "AuditPassword123!",
            passcode: nil,
            fullName: "Audit Complete",
            authMethod: .password
        )

        try await authService.logout()

        _ = try await authService.login(
            email: "auditcomplete@example.com",
            credential: "AuditPassword123!",
            authMethod: .password
        )

        try await authService.logout()

        // Verify all events logged
        let allEvents = try auditLogger.fetchUserEvents(userId: user.id!)

        let hasAccountCreated = allEvents.contains { $0.entry.eventType == "account_created" }
        let hasLoginSuccess = allEvents.contains { $0.entry.eventType == "login_success" }
        let hasLogout = allEvents.contains { $0.entry.eventType == "logout_success" }

        #expect(hasAccountCreated)
        #expect(hasLoginSuccess)
        #expect(hasLogout)
    }
}
