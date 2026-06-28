//
//  EncryptionManager.swift
//  HouseCall
//
//  HIPAA-Compliant Encryption Manager using AES-256-GCM
//  Implements field-level encryption for Protected Health Information (PHI)
//

import Foundation
import CryptoKit

/// Errors that can occur during encryption operations
enum EncryptionError: LocalizedError, Equatable {
    case keyGenerationFailed
    case keyDerivationFailed
    case encryptionFailed
    case decryptionFailed
    case authenticationFailed
    case invalidData
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate encryption key"
        case .keyDerivationFailed:
            return "Failed to derive user-specific key"
        case .encryptionFailed:
            return "Failed to encrypt data"
        case .decryptionFailed:
            return "Failed to decrypt data"
        case .authenticationFailed:
            return "Data integrity check failed - possible tampering detected"
        case .invalidData:
            return "Invalid data format"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        }
    }
}

/// Encrypted data structure containing ciphertext and nonce
struct EncryptedData: Codable {
    let ciphertext: Data
    let nonce: Data

    func toData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func from(data: Data) throws -> EncryptedData {
        try JSONDecoder().decode(EncryptedData.self, from: data)
    }
}

/// Manages AES-256-GCM encryption for PHI with HKDF key derivation
class EncryptionManager {
    static let shared = EncryptionManager()

    private let keychainManager: KeychainManager

    /// Serialises access to the in-memory key caches below.  `EncryptionManager`
    /// is a process-wide singleton that the app drives from concurrent contexts
    /// (streaming AI responses, background cloud sync) and that the test suite
    /// drives from many tests running in parallel.  `masterKey` and
    /// `derivedKeyCache` were previously mutated without synchronisation, which
    /// is a data race: concurrent `Dictionary` mutation can corrupt the heap and
    /// crash the process.  All reads/writes of the two caches go through this
    /// lock.  The lock is never held across Keychain I/O or HKDF derivation, so
    /// it cannot deadlock with itself.
    private let cacheLock = NSLock()
    private var masterKey: SymmetricKey?
    private var derivedKeyCache: [UUID: SymmetricKey] = [:]

    private init(keychainManager: KeychainManager = .shared) {
        self.keychainManager = keychainManager
    }

    // MARK: - Master Key Management

    /// Retrieves or generates the master encryption key.
    ///
    /// Behaviour:
    /// 1. Returns the in-memory cached key immediately (fastest path, also used
    ///    when `_testInjectMasterKey` has been called in `#if DEBUG` builds).
    /// 2. Retrieves an existing key from the Keychain.
    /// 3. Generates a fresh 256-bit key and persists it in the Keychain.
    ///    If the Keychain write fails the error is propagated — silently
    ///    swallowing a write failure would leave the key in-memory only and
    ///    permanently destroy all PHI encrypted under it after the next
    ///    `clearCache()` call or cold launch.
    func getMasterKey() throws -> SymmetricKey {
        // Return cached key if available
        cacheLock.lock()
        let cached = masterKey
        cacheLock.unlock()
        if let cached {
            return cached
        }

        // Try to retrieve existing key from keychain.
        // `retrieveMasterKey()` returns nil ONLY for errSecItemNotFound (genuine
        // first-run) and throws for any other OSStatus.  Using `try` (not `try?`)
        // ensures a transient keychain read error propagates to the caller instead
        // of being silently swallowed — which would cause key regeneration and
        // permanent loss of all previously-encrypted PHI.
        if let keyData = try keychainManager.retrieveMasterKey() {
            let key = SymmetricKey(data: keyData)
            cacheLock.lock()
            masterKey = key
            cacheLock.unlock()
            return key
        }

        // Generate new master key and persist it — propagate any Keychain error.
        let newKey = SymmetricKey(size: .bits256)
        try keychainManager.saveMasterKey(newKey)
        cacheLock.lock()
        masterKey = newKey
        cacheLock.unlock()

        return newKey
    }

    /// Clears the in-memory key caches (master key + derived keys) on logout or
    /// session timeout. This does NOT delete the master key from the Keychain —
    /// at-rest PHI must remain decryptable after the next login; it only evicts
    /// the cached copies from memory so a stale session holds no key material.
    func clearCachedKeys() {
        cacheLock.lock()
        masterKey = nil
        derivedKeyCache.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Key Derivation

    /// Derives a user-specific encryption key using HKDF
    /// - Parameter userId: User UUID used as salt for key derivation
    /// - Returns: User-specific symmetric key
    func getDerivedKey(for userId: UUID) throws -> SymmetricKey {
        // Return cached key if available
        cacheLock.lock()
        let cached = derivedKeyCache[userId]
        cacheLock.unlock()
        if let cached {
            return cached
        }

        // Derive outside the lock — `getMasterKey()` takes the lock itself, so
        // holding it here would deadlock, and HKDF derivation is pure work that
        // needs no synchronisation.  A concurrent caller racing on the same
        // userId derives the identical key (same master + salt), so the only
        // cost of the race is a redundant derivation, never a wrong result.
        let masterKey = try getMasterKey()

        // Use user ID as salt for HKDF
        let salt = Data(userId.uuidString.utf8)

        // Derive user-specific key using HKDF
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: masterKey,
            salt: salt,
            info: Data("HouseCall User Key".utf8),
            outputByteCount: 32
        )

        // Cache the derived key
        cacheLock.lock()
        derivedKeyCache[userId] = derivedKey
        cacheLock.unlock()

        return derivedKey
    }

    // MARK: - Encryption/Decryption

    /// Encrypts data using AES-256-GCM with user-specific derived key
    /// - Parameters:
    ///   - data: Plaintext data to encrypt
    ///   - userId: User UUID for key derivation
    /// - Returns: Encrypted data with nonce
    func encrypt(data: Data, for userId: UUID) throws -> Data {
        let key = try getDerivedKey(for: userId)

        // Encrypt with AES-GCM (provides authentication)
        // The sealed box contains nonce + ciphertext + tag
        guard let sealedBox = try? AES.GCM.seal(data, using: key) else {
            throw EncryptionError.encryptionFailed
        }

        // Return the combined format (this includes nonce, ciphertext, and authentication tag)
        return sealedBox.combined!
    }

    /// Encrypts a string value
    /// - Parameters:
    ///   - string: Plaintext string to encrypt
    ///   - userId: User UUID for key derivation
    /// - Returns: Encrypted data
    func encryptString(_ string: String, for userId: UUID) throws -> Data {
        guard let data = string.data(using: .utf8) else {
            throw EncryptionError.invalidData
        }
        return try encrypt(data: data, for: userId)
    }

    /// Decrypts data using AES-256-GCM with user-specific derived key
    /// - Parameters:
    ///   - encryptedData: Encrypted data containing nonce, ciphertext, and tag
    ///   - userId: User UUID for key derivation
    /// - Returns: Decrypted plaintext data
    func decrypt(encryptedData: Data, for userId: UUID) throws -> Data {
        let key = try getDerivedKey(for: userId)

        // Create sealed box from combined data (nonce + ciphertext + tag)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: encryptedData) else {
            throw EncryptionError.invalidData
        }

        // Decrypt and verify authentication tag
        do {
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            // Authentication failure indicates tampering
            throw EncryptionError.authenticationFailed
        }
    }

    /// Decrypts data to a string
    /// - Parameters:
    ///   - encryptedData: Encrypted data
    ///   - userId: User UUID for key derivation
    /// - Returns: Decrypted string
    func decryptString(_ encryptedData: Data, for userId: UUID) throws -> String {
        let data = try decrypt(encryptedData: encryptedData, for: userId)
        guard let string = String(data: data, encoding: .utf8) else {
            throw EncryptionError.invalidData
        }
        return string
    }

    // MARK: - Cache Management

    /// Clears all cached derived keys (call on logout)
    func clearCache() {
        cacheLock.lock()
        derivedKeyCache.removeAll()
        masterKey = nil
        cacheLock.unlock()
    }

    /// Clears cached key for a specific user
    func clearCache(for userId: UUID) {
        cacheLock.lock()
        derivedKeyCache.removeValue(forKey: userId)
        cacheLock.unlock()
    }

    // MARK: - Test Support

#if DEBUG
    /// Seeds a fixed master key directly into the in-memory cache without
    /// touching the Keychain.
    ///
    /// Call this from test `setUp` / `init` bodies so that `getMasterKey()`
    /// returns immediately without attempting a Keychain read or write.
    /// This prevents `-25299` / `unexpectedStatus` failures in bare or
    /// parallel-test-runner simulator environments where the Keychain may
    /// not be accessible.
    ///
    /// - Parameter key: The key to use as the master encryption key for this
    ///   test session.  Pass a deterministic key (e.g. `SymmetricKey(size: .bits256)`)
    ///   generated once per test class so all operations within the test share
    ///   the same key material.
    func _testInjectMasterKey(_ key: SymmetricKey) {
        cacheLock.lock()
        masterKey = key
        derivedKeyCache.removeAll()
        cacheLock.unlock()
    }

    /// Creates a fresh `EncryptionManager` backed by the supplied
    /// `KeychainManager`.  Intended exclusively for unit tests that need to
    /// inject a mock or stub keychain; **do not call in production code**.
    static func _testMakeInstance(keychainManager: KeychainManager) -> EncryptionManager {
        EncryptionManager(keychainManager: keychainManager)
    }
#endif
}
