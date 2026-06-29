//
//  CloudLoginTests.swift
//  HouseCallTests
//
//  Unit tests for Task 3.2 — login flow through Core API +
//  encryption-identity continuity.
//
//  Coverage:
//  - Cloud login success (existing local user for patientId) → session created,
//    JWT stored, encryption unlocks for the canonical patientId.
//  - Cloud login success when NO local user yet (first device login) → local
//    cache user created keyed by patientId, then session/JWT.
//  - Encryption continuity across register→login: PHI encrypted after register
//    decrypts correctly after login (same HKDF salt = patientId).
//  - Unauthorized (401) → loginFailed thrown, no session, no JWT.
//  - Cloud disabled (nil deps) → unchanged local-only login works.
//

import Testing
import CoreData
import CryptoKit
@testable import HouseCall

// MARK: - Stub

/// Configurable stub satisfying `CoreAPIAuthClientProtocol` for login tests.
/// File-private so it can shadow the private stub in CloudRegistrationTests.swift
/// without any name conflict (each is visible only within its own file).
private final class StubCoreAPIAuthClient: CoreAPIAuthClientProtocol, @unchecked Sendable {
    enum Behaviour {
        case success(token: String, patientId: String)
        case conflict
        case unauthorized
        case offline(String)
    }

    var registerBehaviour: Behaviour
    var loginBehaviour: Behaviour

    /// Convenience init with `loginBehaviour` as the primary parameter.
    init(loginBehaviour: Behaviour, registerBehaviour: Behaviour = .unauthorized) {
        self.loginBehaviour = loginBehaviour
        self.registerBehaviour = registerBehaviour
    }

    func login(tenantId: String, email: String, password: String) async throws -> CoreAPIAuthResult {
        try resolve(loginBehaviour)
    }

    func register(tenantId: String, email: String, password: String, state: String?) async throws -> CoreAPIAuthResult {
        try resolve(registerBehaviour)
    }

    private func resolve(_ behaviour: Behaviour) throws -> CoreAPIAuthResult {
        switch behaviour {
        case .success(let token, let patientId):
            return CoreAPIAuthResult(token: token, patientId: patientId)
        case .conflict:
            throw SyncError.conflict
        case .unauthorized:
            throw SyncError.unauthorized
        case .offline(let reason):
            throw SyncError.offline(reason)
        }
    }
}

// MARK: - CloudLoginTests

@Suite("Cloud Login Tests")
@MainActor
struct CloudLoginTests {

    // MARK: - Helpers

    private func makeContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(
            name: "HouseCall",
            managedObjectModel: TestCoreDataModel.shared
        )
        let desc = NSPersistentStoreDescription()
        desc.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [desc]
        container.loadPersistentStores { _, error in
            if let error { fatalError("In-memory store failed: \(error)") }
        }
        return container.viewContext
    }

    private func makeService(
        context: NSManagedObjectContext,
        keychain: InMemoryKeychainManager,
        stubClient: CoreAPIAuthClientProtocol?,
        tenantId: String?
    ) -> AuthenticationService {
        AuthenticationService(
            userRepository: CoreDataUserRepository(
                context: context,
                encryptionManager: EncryptionManager.shared,
                passwordHasher: PasswordHasher.shared,
                auditLogger: AuditLogger(context: context)
            ),
            keychainManager: keychain,
            biometricAuthManager: .shared,
            auditLogger: AuditLogger(context: context),
            coreAuthClient: stubClient,
            coreAPITenantId: tenantId
        )
    }

    private func makeRepo(context: NSManagedObjectContext) -> CoreDataUserRepository {
        CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )
    }

    // MARK: - Cloud login success: existing local user

    @Test("Cloud login success — existing local user, session created and JWT stored")
    func testCloudLoginExistingLocalUser() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()

        // Pre-create the local cache user keyed by patientId (simulates a prior
        // registration or a previous login on this device).
        let repo = makeRepo(context: context)
        _ = try repo.createUser(
            email: "patient@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Jane Smith",
            authMethod: .password,
            id: patientId
        )

        let stub = StubCoreAPIAuthClient(
            loginBehaviour: .success(token: "login.jwt.123", patientId: patientId.uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        let user = try await service.login(
            email: "patient@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )

        // User identity must match the canonical patientId.
        let userId = try #require(user.id)
        #expect(userId == patientId,
                "Logged-in user.id must equal the Core API patientId")

        // JWT must be stored.
        let storedJWT = try keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == "login.jwt.123",
                "Core API JWT must be written to keychain after successful cloud login")

        // Session must be active.
        await Task.yield()
        #expect(service.isAuthenticated == true,
                "Session must be active after successful cloud login")
    }

    // MARK: - Cloud login success: no local user yet (first device login)

    @Test("Cloud login success — no local user, cache user created keyed by patientId")
    func testCloudLoginFirstDevice() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()

        // No local user exists before login (first login on this device).
        let repo = makeRepo(context: context)
        #expect(repo.findUser(by: patientId) == nil,
                "Precondition: no local user should exist before first-device login")

        let stub = StubCoreAPIAuthClient(
            loginBehaviour: .success(token: "first.jwt", patientId: patientId.uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        let user = try await service.login(
            email: "new@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )

        // User must be created keyed by the canonical patientId.
        let userId = try #require(user.id)
        #expect(userId == patientId,
                "Cache user created on first-device login must be keyed by patientId")

        // Local user must now exist in the store.
        #expect(repo.findUser(by: patientId) != nil,
                "A local cache user must exist after first-device cloud login")

        // JWT and session must be established.
        let storedJWT = try keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == "first.jwt")

        await Task.yield()
        #expect(service.isAuthenticated == true)
    }

    // MARK: - Encryption continuity: register then login

    @Test("Encryption continuity — PHI encrypted after register decrypts after login")
    func testEncryptionContinuityRegisterThenLogin() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()
        let stub = StubCoreAPIAuthClient(
            loginBehaviour: .success(token: "login.jwt", patientId: patientId.uuidString),
            registerBehaviour: .success(token: "reg.jwt", patientId: patientId.uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        // Register — creates local user keyed by patientId.
        let registeredUser = try await service.register(
            email: "cont@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Continuity Patient",
            authMethod: .password
        )
        let registeredId = try #require(registeredUser.id)
        #expect(registeredId == patientId)

        // Encrypt a PHI value using the registered user's identity.
        let plaintext = "blood pressure: 120/80"
        let encryptedPHI = try EncryptionManager.shared.encryptString(plaintext, for: registeredId)

        // Log out so we start a fresh login.
        try await service.logout()

        // Login — must resolve to the same local user (or re-create with the
        // same patientId) and derive the same encryption key.
        let loggedInUser = try await service.login(
            email: "cont@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )
        let loggedInId = try #require(loggedInUser.id)
        #expect(loggedInId == patientId,
                "Login must resolve to the same canonical patientId as registration")

        // PHI encrypted under the registered identity must decrypt under login identity.
        let decrypted = try EncryptionManager.shared.decryptString(encryptedPHI, for: loggedInId)
        #expect(decrypted == plaintext,
                "PHI written after registration must be readable after login (same HKDF salt)")
    }

    // MARK: - Unauthorized (401) → loginFailed

    @Test("Cloud 401 — loginFailed thrown, no session, no JWT")
    func testCloudUnauthorized() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let stub = StubCoreAPIAuthClient(loginBehaviour: .unauthorized)
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        var caughtLoginFailed = false
        do {
            _ = try await service.login(
                email: "bad@example.com",
                credential: "WrongPassword123!",
                authMethod: .password
            )
            Issue.record("Expected loginFailed to be thrown for a 401 response")
        } catch let err as AuthenticationError {
            if case .loginFailed = err {
                caughtLoginFailed = true
            } else {
                Issue.record("Expected .loginFailed, got \(err)")
            }
        }
        #expect(caughtLoginFailed, "401 from Core API must produce loginFailed")

        // No JWT stored.
        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil, "No JWT must be stored when login is rejected with 401")

        // No active session.
        await Task.yield()
        #expect(service.isAuthenticated == false,
                "No session must be started when Core API rejects credentials")
    }

    // MARK: - Cloud disabled (nil deps) → local-only login

    @Test("Cloud disabled — local-only login works unchanged")
    func testLocalOnlyLogin() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        // nil client + nil tenantId → local-only path
        let service = makeService(context: context, keychain: keychain, stubClient: nil, tenantId: nil)

        // Pre-create a local user (local-only registration).
        let repo = makeRepo(context: context)
        let localUser = try repo.createUser(
            email: "local@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Local Patient",
            authMethod: .password
        )
        let localId = try #require(localUser.id)

        let loggedIn = try await service.login(
            email: "local@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )

        let loggedInId = try #require(loggedIn.id)
        #expect(loggedInId == localId,
                "Local-only login must return the pre-existing local user")

        // No JWT should be stored.
        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil, "Local-only login must NOT store a Core API JWT")

        // Session must be active.
        await Task.yield()
        #expect(service.isAuthenticated == true,
                "Session must be active after successful local-only login")
    }
}
