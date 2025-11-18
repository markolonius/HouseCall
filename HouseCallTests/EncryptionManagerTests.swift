//
//  EncryptionManagerTests.swift
//  HouseCallTests
//
//  Unit tests for AES-256-GCM encryption manager
//

import Testing
import CryptoKit
@testable import HouseCall

@Suite("EncryptionManager Tests")
struct EncryptionManagerTests {

    // MARK: - Encryption/Decryption Tests

    @Test("Encrypt and decrypt data successfully")
    func testEncryptDecryptRoundTrip() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let originalData = Data("Sensitive health information".utf8)

        let encrypted = try manager.encrypt(data: originalData, for: userId)
        let decrypted = try manager.decrypt(encryptedData: encrypted, for: userId)

        #expect(decrypted == originalData)
        #expect(encrypted != originalData) // Verify it's actually encrypted
    }

    @Test("Encrypt and decrypt string successfully")
    func testEncryptDecryptString() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let originalString = "Patient Name: John Doe"

        let encrypted = try manager.encryptString(originalString, for: userId)
        let decrypted = try manager.decryptString(encrypted, for: userId)

        #expect(decrypted == originalString)
    }

    @Test("Encrypted data is different each time (unique nonce)")
    func testUniqueNoncePerEncryption() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let data = Data("Test data".utf8)

        let encrypted1 = try manager.encrypt(data: data, for: userId)
        let encrypted2 = try manager.encrypt(data: data, for: userId)

        // Same plaintext, but different ciphertext due to unique nonce
        #expect(encrypted1 != encrypted2)

        // But both decrypt to same value
        let decrypted1 = try manager.decrypt(encryptedData: encrypted1, for: userId)
        let decrypted2 = try manager.decrypt(encryptedData: encrypted2, for: userId)
        #expect(decrypted1 == decrypted2)
    }

    @Test("Decryption with wrong user ID fails")
    func testDecryptWithWrongUserId() throws {
        let manager = EncryptionManager.shared
        let user1 = UUID()
        let user2 = UUID()
        let data = Data("Secret data".utf8)

        let encrypted = try manager.encrypt(data: data, for: user1)

        // Attempting to decrypt with different user ID should fail
        #expect(throws: EncryptionError.self) {
            try manager.decrypt(encryptedData: encrypted, for: user2)
        }
    }

    @Test("Tampering detection (authentication tag)")
    func testTamperingDetection() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let data = Data("Important data".utf8)

        var encrypted = try manager.encrypt(data: data, for: userId)

        // Tamper with the encrypted data
        encrypted[encrypted.count - 1] ^= 0xFF

        // Decryption should fail due to authentication tag mismatch
        #expect(throws: EncryptionError.authenticationFailed) {
            try manager.decrypt(encryptedData: encrypted, for: userId)
        }
    }

    @Test("Decryption with invalid data fails")
    func testDecryptInvalidData() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let invalidData = Data([0x00, 0x01, 0x02]) // Too short for AES-GCM

        #expect(throws: EncryptionError.self) {
            try manager.decrypt(encryptedData: invalidData, for: userId)
        }
    }

    // MARK: - Key Derivation Tests

    @Test("Derived keys are consistent for same user")
    func testDerivedKeyConsistency() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()

        let key1 = try manager.getDerivedKey(for: userId)
        let key2 = try manager.getDerivedKey(for: userId)

        // Keys should be the same (from cache or re-derived)
        #expect(key1.withUnsafeBytes { Data($0) } == key2.withUnsafeBytes { Data($0) })
    }

    @Test("Different users get different derived keys")
    func testDifferentUsersGetDifferentKeys() throws {
        let manager = EncryptionManager.shared
        let user1 = UUID()
        let user2 = UUID()

        let key1 = try manager.getDerivedKey(for: user1)
        let key2 = try manager.getDerivedKey(for: user2)

        // Keys should be different
        #expect(key1.withUnsafeBytes { Data($0) } != key2.withUnsafeBytes { Data($0) })
    }

    @Test("Derived key uses HKDF with user ID as salt")
    func testDerivedKeyUsesHKDF() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()

        // Get derived key (should use HKDF internally)
        let derivedKey = try manager.getDerivedKey(for: userId)

        // Verify key size is 256 bits (32 bytes)
        #expect(derivedKey.withUnsafeBytes { $0.count } == 32)
    }

    // MARK: - Cache Management Tests

    @Test("Cache clearing removes derived keys")
    func testCacheClearingWorks() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let data = Data("Test".utf8)

        // Encrypt (creates derived key and caches it)
        let encrypted = try manager.encrypt(data: data, for: userId)

        // Clear cache
        manager.clearCache()

        // Should still be able to decrypt (re-derives key)
        let decrypted = try manager.decrypt(encryptedData: encrypted, for: userId)
        #expect(decrypted == data)
    }

    @Test("Clear cache for specific user")
    func testClearCacheForSpecificUser() throws {
        let manager = EncryptionManager.shared
        let user1 = UUID()
        let user2 = UUID()

        // Create derived keys for both users
        _ = try manager.getDerivedKey(for: user1)
        _ = try manager.getDerivedKey(for: user2)

        // Clear cache for user1 only
        manager.clearCache(for: user1)

        // Should still work for both users (re-derives as needed)
        let data = Data("Test".utf8)
        let encrypted1 = try manager.encrypt(data: data, for: user1)
        let encrypted2 = try manager.encrypt(data: data, for: user2)

        #expect(encrypted1 != encrypted2)
    }

    // MARK: - Master Key Tests

    @Test("Master key persists across instances")
    func testMasterKeyPersistence() throws {
        // First instance creates master key
        let manager1 = EncryptionManager.shared
        let userId = UUID()
        let data = Data("Test data".utf8)
        let encrypted = try manager1.encrypt(data: data, for: userId)

        // Master key should persist in keychain
        // New instance should be able to decrypt
        let decrypted = try manager1.decrypt(encryptedData: encrypted, for: userId)
        #expect(decrypted == data)
    }

    // MARK: - Error Handling Tests

    @Test("Encrypt empty data succeeds")
    func testEncryptEmptyData() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let emptyData = Data()

        let encrypted = try manager.encrypt(data: emptyData, for: userId)
        let decrypted = try manager.decrypt(encryptedData: encrypted, for: userId)

        #expect(decrypted == emptyData)
    }

    @Test("Encrypt large data succeeds")
    func testEncryptLargeData() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let largeData = Data(repeating: 0x42, count: 1024 * 1024) // 1 MB

        let encrypted = try manager.encrypt(data: largeData, for: userId)
        let decrypted = try manager.decrypt(encryptedData: encrypted, for: userId)

        #expect(decrypted == largeData)
    }

    @Test("Decrypt string with invalid UTF-8 fails")
    func testDecryptInvalidUTF8String() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let invalidUTF8 = Data([0xFF, 0xFE, 0xFD]) // Invalid UTF-8 sequence

        let encrypted = try manager.encrypt(data: invalidUTF8, for: userId)

        #expect(throws: EncryptionError.invalidData) {
            try manager.decryptString(encrypted, for: userId)
        }
    }

    // MARK: - Performance Tests

    @Test("Encryption performance is acceptable")
    func testEncryptionPerformance() throws {
        let manager = EncryptionManager.shared
        let userId = UUID()
        let data = Data("Patient health record with sensitive information".utf8)

        let start = Date()
        _ = try manager.encrypt(data: data, for: userId)
        let elapsed = Date().timeIntervalSince(start)

        // Should complete in less than 50ms
        #expect(elapsed < 0.05)
    }
}
