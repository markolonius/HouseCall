//
//  CloudActivationTests.swift
//  HouseCallTests
//
//  Unit tests for Task 5.2 — cloud sync activation from build-time config.
//
//  Coverage:
//  - Config-gating: with both URL + tenant present, AuthenticationService is
//    cloud-enabled (coreAuthClient non-nil, coreAPITenantId non-nil).
//  - Config-gating: with URL absent, instance is local-only.
//  - Config-gating: with tenantId absent, instance is local-only.
//  - Config-gating: with both absent, instance is local-only.
//  - JWT gate: after a successful cloud login the JWT is in the Keychain so
//    buildCloudSyncCoordinator's JWT gate would pass.
//
//  Tests use `AuthenticationService._testMakeInstance(coreAPIBaseURLString:tenantId:)`
//  to exercise the factory logic without touching Bundle.main or the singleton.
//  The JWT test uses a StubCoreAPIAuthClient (file-private) to stay hermetic.
//

import Testing
import CoreData
@testable import HouseCall

// MARK: - Stub

/// File-private stub satisfying `CoreAPIAuthClientProtocol`.
/// Avoids any naming conflict with identical private stubs in other test files.
private final class StubCoreAPIAuthClientActivation: CoreAPIAuthClientProtocol, @unchecked Sendable {
    enum Behaviour {
        case success(token: String, patientId: String)
        case unauthorized
        case offline(String)
    }

    let loginBehaviour: Behaviour
    let registerBehaviour: Behaviour

    init(loginBehaviour: Behaviour, registerBehaviour: Behaviour = .unauthorized) {
        self.loginBehaviour = loginBehaviour
        self.registerBehaviour = registerBehaviour
    }

    func login(tenantId: String, email: String, password: String) async throws -> CoreAPIAuthResult {
        try resolve(loginBehaviour)
    }

    func register(tenantId: String, email: String, password: String) async throws -> CoreAPIAuthResult {
        try resolve(registerBehaviour)
    }

    private func resolve(_ b: Behaviour) throws -> CoreAPIAuthResult {
        switch b {
        case .success(let token, let patientId):
            return CoreAPIAuthResult(token: token, patientId: patientId)
        case .unauthorized:
            throw SyncError.unauthorized
        case .offline(let reason):
            throw SyncError.offline(reason)
        }
    }
}

// MARK: - CloudActivationTests

@Suite("Cloud Activation Tests")
@MainActor
struct CloudActivationTests {

    // MARK: - Config-gating

    @Test("Factory: cloud-enabled when both URL and tenantId are present")
    func testCloudEnabledWhenBothConfigsPresent() {
        let svc = AuthenticationService._testMakeInstance(
            coreAPIBaseURLString: "http://localhost:8080",
            tenantId: "tenant-uuid-1234"
        )
        #expect(svc._testIsCloudEnabled == true,
                "Instance must be cloud-enabled when base URL and tenant ID are both provided")
    }

    @Test("Factory: local-only when URL is absent")
    func testLocalOnlyWhenURLAbsent() {
        let svc = AuthenticationService._testMakeInstance(
            coreAPIBaseURLString: nil,
            tenantId: "tenant-uuid-1234"
        )
        #expect(svc._testIsCloudEnabled == false,
                "Instance must be local-only when base URL is nil")
    }

    @Test("Factory: local-only when tenantId is absent")
    func testLocalOnlyWhenTenantIdAbsent() {
        let svc = AuthenticationService._testMakeInstance(
            coreAPIBaseURLString: "http://localhost:8080",
            tenantId: nil
        )
        #expect(svc._testIsCloudEnabled == false,
                "Instance must be local-only when tenant ID is nil")
    }

    @Test("Factory: local-only when both configs are absent")
    func testLocalOnlyWhenBothConfigsAbsent() {
        let svc = AuthenticationService._testMakeInstance(
            coreAPIBaseURLString: nil,
            tenantId: nil
        )
        #expect(svc._testIsCloudEnabled == false,
                "Instance must be local-only when both configs are nil")
    }

    // MARK: - JWT gate

    /// After a successful cloud login the JWT is in the Keychain.
    /// This is the same JWT that `buildCloudSyncCoordinator` checks; if the
    /// gate passes the coordinator is built and `AIConversationService` runs
    /// through Core API.
    @Test("Cloud login stores JWT so sync coordinator gate passes")
    func testCloudLoginStoresJWTForSyncGate() async throws {
        // Arrange — in-memory Core Data + keychain so nothing touches disk.
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
        let context = container.viewContext
        let keychain = InMemoryKeychainManager()

        let expectedJWT = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.stub"
        let canonicalPatientId = UUID().uuidString
        let stub = StubCoreAPIAuthClientActivation(
            loginBehaviour: .success(token: expectedJWT, patientId: canonicalPatientId)
        )

        // Build the service with an in-memory repo + keychain + stub cloud client.
        let svc = AuthenticationService(
            userRepository: CoreDataUserRepository(
                context: context,
                encryptionManager: EncryptionManager.shared,
                passwordHasher: PasswordHasher.shared,
                auditLogger: AuditLogger(context: context)
            ),
            keychainManager: keychain,
            biometricAuthManager: .shared,
            auditLogger: AuditLogger(context: context),
            coreAuthClient: stub,
            coreAPITenantId: "tenant-activates-sync"
        )

        // Act — cloud login.
        _ = try await svc.login(
            email: "patient@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )

        // Assert — JWT must be in the keychain under the key that
        // buildCloudSyncCoordinator reads.
        let storedJWT = try keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        let unwrappedJWT = try #require(storedJWT, "JWT must be present in keychain after cloud login")
        #expect(unwrappedJWT == expectedJWT,
                "JWT written by login must be present under coreAPIJWT so the sync-coordinator JWT gate passes")
        #expect(!unwrappedJWT.isEmpty,
                "JWT must be non-empty so the gate's isEmpty guard does not reject it")
    }
}
