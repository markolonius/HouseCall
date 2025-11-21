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
    private var masterKey: SymmetricKey?
    private var derivedKeyCache: [UUID: SymmetricKey] = [:]

    private init(keychainManager: KeychainManager = .shared) {
        self.keychainManager = keychainManager
    }

    // MARK: - Master Key Management

    /// Retrieves or generates the master encryption key
    func getMasterKey() throws -> SymmetricKey {
        // Return cached key if available
        if let masterKey = masterKey {
            return masterKey
        }

        // Try to retrieve existing key from keychain
        if let keyData = try? keychainManager.retrieveMasterKey() {
            let key = SymmetricKey(data: keyData)
            masterKey = key
            return key
        }

        // Generate new master key
        let newKey = SymmetricKey(size: .bits256)
        try keychainManager.saveMasterKey(newKey)
        masterKey = newKey

        return newKey
    }

    // MARK: - Key Derivation

    /// Derives a user-specific encryption key using HKDF
    /// - Parameter userId: User UUID used as salt for key derivation
    /// - Returns: User-specific symmetric key
    func getDerivedKey(for userId: UUID) throws -> SymmetricKey {
        // Return cached key if available
        if let cachedKey = derivedKeyCache[userId] {
            return cachedKey
        }

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
        derivedKeyCache[userId] = derivedKey

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
        derivedKeyCache.removeAll()
        masterKey = nil
    }

    /// Clears cached key for a specific user
    func clearCache(for userId: UUID) {
        derivedKeyCache.removeValue(forKey: userId)
    }
}
