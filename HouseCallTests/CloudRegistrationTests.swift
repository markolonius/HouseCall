//
//  CloudRegistrationTests.swift
//  HouseCallTests
//
//  Unit tests for Task 3.1 — registration flow through Core API.
//
//  Coverage:
//  - Cloud register success: local user id equals server-canonical patientId.
//  - JWT stored in keychain after cloud registration.
//  - Session created (isAuthenticated) after cloud registration.
//  - Encryption-identity continuity: getDerivedKey(user.id) == getDerivedKey(patientId)
//    and PHI round-trips correctly.
//  - Cloud disabled (nil deps): unchanged local-only registration path.
//  - 409 conflict: registrationFailed error thrown, no local user created, no JWT stored.
//  - Network offline: registrationFailed error with connectivity description.
//

import Testing
import CoreData
import CryptoKit
@testable import HouseCall

// MARK: - StubCoreAPIAuthClient

/// Configurable stub satisfying `CoreAPIAuthClientProtocol`.
/// Never touches the network; returns or throws a caller-specified result.
private final class StubCoreAPIAuthClient: CoreAPIAuthClientProtocol, @unchecked Sendable {
    enum Behaviour {
        case success(token: String, patientId: String)
        case conflict
        case unauthorized
        case offline(String)
    }

    var registerBehaviour: Behaviour
    var loginBehaviour: Behaviour

    init(registerBehaviour: Behaviour, loginBehaviour: Behaviour = .unauthorized) {
        self.registerBehaviour = registerBehaviour
        self.loginBehaviour = loginBehaviour
    }

    func register(tenantId: String, email: String, password: String, state: String?) async throws -> CoreAPIAuthResult {
        try resolve(registerBehaviour)
    }

    func login(tenantId: String, email: String, password: String) async throws -> CoreAPIAuthResult {
        try resolve(loginBehaviour)
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

// MARK: - CloudRegistrationTests

@Suite("Cloud Registration Tests")
@MainActor
struct CloudRegistrationTests {

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

    // MARK: - Cloud register success: user.id == patientId

    @Test("Cloud register success — local user.id equals server-canonical patientId")
    func testCloudRegisterUserKeyedByPatientId() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let canonicalPatientId = UUID()
        let stub = StubCoreAPIAuthClient(
            registerBehaviour: .success(token: "tok", patientId: canonicalPatientId.uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        let user = try await service.register(
            email: "patient@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Jane Smith",
            authMethod: .password
        )

        let userId = try #require(user.id, "User must have an id")
        #expect(userId == canonicalPatientId,
                "local user.id must equal the Core API patientId for encryption-identity continuity")
    }

    // MARK: - Cloud register success: JWT stored

    @Test("Cloud register success — JWT persisted to keychain")
    func testCloudRegisterJWTStored() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let stub = StubCoreAPIAuthClient(
            registerBehaviour: .success(token: "jwt.abc.123", patientId: UUID().uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        _ = try await service.register(
            email: "jwt@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "JWT Patient",
            authMethod: .password
        )

        let storedJWT = try keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == "jwt.abc.123",
                "Core API JWT must be written to keychain after successful cloud registration")
    }

    // MARK: - Cloud register success: session created

    @Test("Cloud register success — session is active after registration")
    func testCloudRegisterSessionCreated() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let stub = StubCoreAPIAuthClient(
            registerBehaviour: .success(token: "tok", patientId: UUID().uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        _ = try await service.register(
            email: "session@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Session Patient",
            authMethod: .password
        )

        // createSession defers @Published updates to the next run-loop cycle.
        await Task.yield()
        #expect(service.isAuthenticated == true,
                "Session must be active immediately after cloud registration")
    }

    // MARK: - Encryption-identity continuity

    @Test("Encryption continuity — getDerivedKey(user.id) equals getDerivedKey(patientId)")
    func testEncryptionKeyIdentity() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()
        let stub = StubCoreAPIAuthClient(
            registerBehaviour: .success(token: "tok", patientId: patientId.uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        let user = try await service.register(
            email: "enc@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Enc Patient",
            authMethod: .password
        )

        let userId = try #require(user.id)

        // Both calls use the same UUID (userId == patientId) → must derive identical keys.
        let keyA = try EncryptionManager.shared.getDerivedKey(for: userId)
        let keyB = try EncryptionManager.shared.getDerivedKey(for: patientId)

        // SymmetricKey is not Equatable; compare raw bytes.
        let bytesA = keyA.withUnsafeBytes { Data($0) }
        let bytesB = keyB.withUnsafeBytes { Data($0) }
        #expect(bytesA == bytesB,
                "HKDF-derived key must be identical when user.id == patientId")
    }

    @Test("Encryption continuity — PHI encrypted for user.id decrypts under patientId")
    func testPHIRoundTrip() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()
        let stub = StubCoreAPIAuthClient(
            registerBehaviour: .success(token: "tok", patientId: patientId.uuidString)
        )
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        let user = try await service.register(
            email: "phi@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "PHI Patient",
            authMethod: .password
        )

        let userId = try #require(user.id)
        let plaintext = "sensitive health information"
        let encrypted = try EncryptionManager.shared.encryptString(plaintext, for: userId)
        let decrypted = try EncryptionManager.shared.decryptString(encrypted, for: patientId)
        #expect(decrypted == plaintext,
                "PHI encrypted under user.id must round-trip correctly under the canonical patientId")
    }

    // MARK: - Cloud disabled (nil deps) — local path unchanged

    @Test("Cloud disabled — local-only registration creates user with a generated id")
    func testLocalOnlyRegistration() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        // nil client + nil tenantId → local-only path
        let service = makeService(context: context, keychain: keychain, stubClient: nil, tenantId: nil)

        let user = try await service.register(
            email: "local@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Local Patient",
            authMethod: .password
        )

        #expect(user.email == "local@example.com")
        #expect(user.id != nil, "Local user must still receive a generated id")

        // No JWT must be stored for a local-only registration.
        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil, "Local-only registration must NOT store a Core API JWT")
    }

    // MARK: - 409 conflict

    @Test("Cloud 409 conflict — registrationFailed error, no local user, no JWT")
    func testCloudConflict() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let stub = StubCoreAPIAuthClient(registerBehaviour: .conflict)
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        var caughtRegistrationFailed = false
        do {
            _ = try await service.register(
                email: "dup@example.com",
                password: "SecurePassword123!",
                passcode: nil,
                fullName: "Duplicate",
                authMethod: .password
            )
            Issue.record("Expected registrationFailed to be thrown for a 409 conflict")
        } catch let err as AuthenticationError {
            if case .registrationFailed(let reason) = err {
                caughtRegistrationFailed = true
                // Error description must reference email (duplicate account concept).
                #expect(reason.lowercased().contains("email") || reason.lowercased().contains("registered"),
                        "registrationFailed reason should mention duplicate email; got: \(reason)")
            } else {
                Issue.record("Expected .registrationFailed, got \(err)")
            }
        }
        #expect(caughtRegistrationFailed)

        // Verify no local user was persisted.
        let repo = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )
        #expect(repo.findUser(by: "dup@example.com") == nil,
                "No local user must be created when Core API returns 409")

        // Verify no JWT was stored.
        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil, "No JWT must be stored when registration fails with 409")
    }

    // MARK: - Network offline

    @Test("Cloud offline — registrationFailed error with connectivity description")
    func testCloudOffline() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let stub = StubCoreAPIAuthClient(registerBehaviour: .offline("no route to host"))
        let service = makeService(context: context, keychain: keychain, stubClient: stub, tenantId: "t-1")

        var caughtRegistrationFailed = false
        do {
            _ = try await service.register(
                email: "offline@example.com",
                password: "SecurePassword123!",
                passcode: nil,
                fullName: "Offline Patient",
                authMethod: .password
            )
            Issue.record("Expected registrationFailed to be thrown when server is unreachable")
        } catch let err as AuthenticationError {
            if case .registrationFailed(let reason) = err {
                caughtRegistrationFailed = true
                let lower = reason.lowercased()
                #expect(lower.contains("connectivity") || lower.contains("network") || lower.contains("offline"),
                        "registrationFailed reason should indicate network issue; got: \(reason)")
            } else {
                Issue.record("Expected .registrationFailed, got \(err)")
            }
        }
        #expect(caughtRegistrationFailed)
    }
}
