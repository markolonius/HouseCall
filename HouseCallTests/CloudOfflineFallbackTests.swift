//
//  CloudOfflineFallbackTests.swift
//  HouseCallTests
//
//  Unit tests for Task 4.1 — offline fallback login.
//
//  Coverage:
//  - offline + pre-existing local user, correct credential
//      → local session created, isAuthenticated == true, NO JWT stored.
//  - offline + pre-existing local user, wrong credential
//      → loginFailed, no session.
//  - offline + NO local user
//      → loginFailed, no session.
//  - 401 (unauthorized) with a pre-existing local user whose credential matches
//      → loginFailed, no session, offline fallback NOT consulted.
//      (If the fallback were incorrectly triggered on 401 the login would succeed;
//       a loginFailed result proves Core API rejection still fails closed.)
//  - Confirm unreachable (.offline) vs rejected (.unauthorized) is the deciding
//    factor.
//

import Testing
import CoreData
@testable import HouseCall

// MARK: - CloudOfflineFallbackTests

@Suite("Cloud Offline Fallback Tests")
@MainActor
struct CloudOfflineFallbackTests {

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

    private func makeRepo(context: NSManagedObjectContext) -> CoreDataUserRepository {
        CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )
    }

    private func makeService(
        context: NSManagedObjectContext,
        keychain: InMemoryKeychainManager,
        stubBehaviour: StubOfflineAuthClient.Behaviour
    ) -> AuthenticationService {
        let stub = StubOfflineAuthClient(loginBehaviour: stubBehaviour)
        return AuthenticationService(
            userRepository: makeRepo(context: context),
            keychainManager: keychain,
            biometricAuthManager: .shared,
            auditLogger: AuditLogger(context: context),
            coreAuthClient: stub,
            coreAPITenantId: "tenant-offline-test"
        )
    }

    // MARK: - Offline + correct credential → local session

    @Test("Offline + existing user, correct credential — local session created, no JWT")
    func testOfflineLogin_existingUser_correctCredential() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()

        // Pre-create a cached local user (simulates a prior successful cloud login).
        let repo = makeRepo(context: context)
        _ = try repo.createUser(
            email: "offline@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Offline Patient",
            authMethod: .password,
            id: patientId
        )

        let service = makeService(context: context, keychain: keychain, stubBehaviour: .offline("no route"))

        let user = try await service.login(
            email: "offline@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )

        // Must resolve to the cached local user.
        let userId = try #require(user.id)
        #expect(userId == patientId,
                "Offline fallback must return the cached local user keyed by patientId")

        // NO JWT must be stored — none was obtained from the server.
        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil,
                "No JWT must be stored when login succeeds via offline fallback")

        // Session must be active (encryption unlocked for the local record).
        await Task.yield()
        #expect(service.isAuthenticated == true,
                "isAuthenticated must be true after successful offline fallback login")
    }

    // MARK: - Offline + correct credential → encryption identity preserved

    @Test("Offline + existing user — encryption identity (user.id) matches cached local user")
    func testOfflineLogin_encryptionIdentityPreserved() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()

        let repo = makeRepo(context: context)
        _ = try repo.createUser(
            email: "eid@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "EID Patient",
            authMethod: .password,
            id: patientId
        )

        // Encrypt a PHI value under the local user's identity.
        let plaintext = "temperature: 37.2 C"
        let encryptedPHI = try EncryptionManager.shared.encryptString(plaintext, for: patientId)

        let service = makeService(context: context, keychain: keychain, stubBehaviour: .offline("timeout"))

        let user = try await service.login(
            email: "eid@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )

        let userId = try #require(user.id)
        // The returned user.id must equal patientId so the caller can derive the
        // same encryption key — no new identity must be created offline.
        #expect(userId == patientId,
                "Offline login must return the same user.id as the cached local record")

        // PHI encrypted before the offline login must still be readable.
        let decrypted = try EncryptionManager.shared.decryptString(encryptedPHI, for: userId)
        #expect(decrypted == plaintext,
                "PHI encrypted under the cached identity must remain readable after offline login")
    }

    // MARK: - Offline + wrong credential → loginFailed

    @Test("Offline + existing user, wrong credential — loginFailed, no session")
    func testOfflineLogin_existingUser_wrongCredential() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()

        let repo = makeRepo(context: context)
        _ = try repo.createUser(
            email: "offline2@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Offline Patient 2",
            authMethod: .password,
            id: patientId
        )

        let service = makeService(context: context, keychain: keychain, stubBehaviour: .offline("no route"))

        var caughtLoginFailed = false
        do {
            _ = try await service.login(
                email: "offline2@example.com",
                credential: "WrongPassword999!",     // wrong credential
                authMethod: .password
            )
            Issue.record("Expected loginFailed to be thrown for wrong offline credential")
        } catch let err as AuthenticationError {
            if case .loginFailed = err {
                caughtLoginFailed = true
            } else {
                Issue.record("Expected .loginFailed, got \(err)")
            }
        }
        #expect(caughtLoginFailed,
                "Wrong credential during offline fallback must produce loginFailed")

        // No JWT stored.
        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil)

        // No session.
        await Task.yield()
        #expect(service.isAuthenticated == false,
                "No session must be started when offline credential check fails")
    }

    // MARK: - Offline + no local user → loginFailed

    @Test("Offline + no local user — loginFailed, no session")
    func testOfflineLogin_noLocalUser() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()

        // No local user exists (e.g. first-ever login on this device while offline).
        let service = makeService(context: context, keychain: keychain, stubBehaviour: .offline("unreachable"))

        var caughtLoginFailed = false
        do {
            _ = try await service.login(
                email: "nobody@example.com",
                credential: "SecurePassword123!",
                authMethod: .password
            )
            Issue.record("Expected loginFailed when offline with no cached local user")
        } catch let err as AuthenticationError {
            if case .loginFailed = err {
                caughtLoginFailed = true
            } else {
                Issue.record("Expected .loginFailed, got \(err)")
            }
        }
        #expect(caughtLoginFailed,
                "Offline with no cached local user must produce loginFailed")

        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil)

        await Task.yield()
        #expect(service.isAuthenticated == false)
    }

    // MARK: - 401 (unauthorized) — no offline fallback, fails closed

    @Test("401 unauthorized — loginFailed, offline fallback NOT used even with a valid local cache user")
    func testUnauthorized_noOfflineFallback() async throws {
        let context = makeContext()
        let keychain = InMemoryKeychainManager()
        let patientId = UUID()

        // Pre-create a local user whose credential MATCHES what we'll pass to login.
        // If the offline fallback were incorrectly triggered on a 401, the login
        // would succeed (because the local credential is correct).  A loginFailed
        // result proves the fallback is NOT consulted for 401.
        let repo = makeRepo(context: context)
        _ = try repo.createUser(
            email: "rejected@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Rejected Patient",
            authMethod: .password,
            id: patientId
        )

        let service = makeService(context: context, keychain: keychain, stubBehaviour: .unauthorized)

        var caughtLoginFailed = false
        do {
            _ = try await service.login(
                email: "rejected@example.com",
                credential: "SecurePassword123!",   // correct locally, but server says 401
                authMethod: .password
            )
            Issue.record("Expected loginFailed for a 401 response")
        } catch let err as AuthenticationError {
            if case .loginFailed = err {
                caughtLoginFailed = true
            } else {
                Issue.record("Expected .loginFailed, got \(err)")
            }
        }

        #expect(caughtLoginFailed,
                "Core API 401 must produce loginFailed — offline fallback must NOT be used")

        // No JWT stored.
        let storedJWT = try? keychain.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(storedJWT == nil,
                "No JWT must be stored when Core API rejects with 401")

        // No session — fail closed regardless of local credential state.
        await Task.yield()
        #expect(service.isAuthenticated == false,
                "No session must be started when Core API explicitly rejects credentials")
    }

    // MARK: - Unreachable-vs-rejected is the deciding factor

    @Test("Unreachable vs rejected — only .offline triggers fallback; .unauthorized does not")
    func testOfflineVsUnauthorizedDistinction() async throws {
        let context = makeContext()
        let keychain1 = InMemoryKeychainManager()
        let keychain2 = InMemoryKeychainManager()
        let patientId = UUID()

        // Pre-create identical local users in two separate in-memory stores.
        let repo1 = makeRepo(context: context)
        _ = try repo1.createUser(
            email: "test@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Test Patient",
            authMethod: .password,
            id: patientId
        )

        // Service A — Core API unreachable (.offline).
        let serviceOffline = makeService(
            context: context,
            keychain: keychain1,
            stubBehaviour: .offline("timeout")
        )

        // Service B — Core API reachable but rejects credentials (.unauthorized).
        let serviceUnauthorized = makeService(
            context: context,
            keychain: keychain2,
            stubBehaviour: .unauthorized
        )

        // Offline path: should succeed via local fallback.
        let offlineUser = try await serviceOffline.login(
            email: "test@example.com",
            credential: "SecurePassword123!",
            authMethod: .password
        )
        await Task.yield()
        #expect(serviceOffline.isAuthenticated == true,
                ".offline must allow login via local fallback when credential matches")
        let offlineId = try #require(offlineUser.id)
        #expect(offlineId == patientId)

        // Unauthorized path: should fail closed.
        var unauthorizedFailed = false
        do {
            _ = try await serviceUnauthorized.login(
                email: "test@example.com",
                credential: "SecurePassword123!",
                authMethod: .password
            )
            Issue.record("Expected loginFailed for .unauthorized")
        } catch let err as AuthenticationError {
            if case .loginFailed = err { unauthorizedFailed = true }
        }
        await Task.yield()
        #expect(unauthorizedFailed,
                ".unauthorized must fail closed regardless of local credential state")
        #expect(serviceUnauthorized.isAuthenticated == false,
                "No session must be started when Core API explicitly rejects credentials")

        // Confirm the distinction: .offline succeeded, .unauthorized failed.
        #expect(serviceOffline.isAuthenticated == true)
        #expect(serviceUnauthorized.isAuthenticated == false)
    }
}

// MARK: - Stub

/// File-private stub for offline fallback tests.
/// Configurable to throw .offline or .unauthorized to exercise the
/// unreachable-vs-rejected distinction without live network access.
private final class StubOfflineAuthClient: CoreAPIAuthClientProtocol, @unchecked Sendable {
    enum Behaviour {
        case offline(String)
        case unauthorized
    }

    let loginBehaviour: Behaviour

    init(loginBehaviour: Behaviour) {
        self.loginBehaviour = loginBehaviour
    }

    func login(tenantId: String, email: String, password: String) async throws -> CoreAPIAuthResult {
        switch loginBehaviour {
        case .offline(let reason):
            throw SyncError.offline(reason)
        case .unauthorized:
            throw SyncError.unauthorized
        }
    }

    func register(tenantId: String, email: String, password: String, state: String?) async throws -> CoreAPIAuthResult {
        // Registration is not exercised in these tests.
        throw SyncError.offline("not implemented in offline stub")
    }
}
