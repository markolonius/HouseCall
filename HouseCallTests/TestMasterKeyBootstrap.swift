//
//  TestMasterKeyBootstrap.swift
//  HouseCallTests
//
//  Ensures EncryptionManager.shared has a master key seeded in-memory before
//  any test in the suite that touches encryption runs.
//
//  Problem: EncryptionManager.getMasterKey() falls back to generating a new key
//  and writing it to the Keychain.  In a bare simulator (or when the parallel
//  test runner spawns isolated processes) the Keychain write can fail with
//  errSecMissingEntitlement / unexpectedStatus.  Seeding the key directly into
//  the in-memory cache avoids the Keychain entirely for test code.
//
//  Usage: this file is compiled into the HouseCallTests target.  The
//  `EncryptionBootstrap` suite's `init()` runs before the first test in each
//  parallel worker, ensuring the shared `EncryptionManager` is ready.
//
//  The seeded key is deterministic within a test-runner invocation (generated
//  once via `SymmetricKey(size: .bits256)`) so all tests in the same process
//  share the same key material.
//

import Foundation
import CryptoKit
import Testing
@testable import HouseCall

/// Module-level master key used by all tests in this process.
///
/// Generating it once (rather than per-test) keeps derived-key caches valid
/// across multiple tests that encrypt/decrypt with the same user ID.
let testMasterKey: SymmetricKey = SymmetricKey(size: .bits256)

/// A fully in-memory `KeychainManager` for tests.
///
/// The iOS Simulator keychain is unavailable to an unsigned test host
/// (`CODE_SIGNING_ALLOWED=NO`, as CI builds it): every `SecItemAdd` /
/// `SecItemCopyMatching` returns `errSecMissingEntitlement` (-34018).  This
/// double overrides the three primitive keychain operations with a lock-guarded
/// dictionary, so keychain-exercising tests run deterministically without any
/// entitlement and in full isolation from each other and from the production
/// `KeychainManager.shared` namespace.
final class InMemoryKeychainManager: KeychainManager, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Data] = [:]

    override func save(data: Data, for key: String, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        lock.lock(); defer { lock.unlock() }
        store[key] = data
    }

    override func retrieve(for key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    override func delete(for key: String) throws {
        lock.lock(); defer { lock.unlock() }
        store.removeValue(forKey: key)
    }
}

/// Runs before any test in the suite and seeds the shared EncryptionManager.
@Suite("Encryption Bootstrap")
struct EncryptionBootstrap {
    init() {
        // Seed the in-memory master key so Keychain access is never required
        // during the test run.  This is idempotent — calling it multiple times
        // clears the derived-key cache but the master key stays the same.
        EncryptionManager.shared._testInjectMasterKey(testMasterKey)
    }

    @Test("Master key is seeded and encryption round-trips correctly")
    func testMasterKeySeeded() throws {
        let userId = UUID()
        let plaintext = "bootstrap seed verification"
        let encrypted = try EncryptionManager.shared.encryptString(plaintext, for: userId)
        let decrypted = try EncryptionManager.shared.decryptString(encrypted, for: userId)
        #expect(decrypted == plaintext)
    }
}
