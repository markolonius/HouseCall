//
//  KeychainManager.swift
//  HouseCall
//
//  Secure keychain storage for encryption keys and session tokens
//  Uses kSecAttrAccessibleWhenUnlockedThisDeviceOnly for HIPAA compliance
//

import Foundation
import Security
import CryptoKit

/// Errors that can occur during keychain operations
enum KeychainError: LocalizedError {
    case itemNotFound
    case duplicateItem
    case invalidData
    case unexpectedStatus(OSStatus)
    case encodingFailed
    case decodingFailed

    var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "Item not found in keychain"
        case .duplicateItem:
            return "Item already exists in keychain"
        case .invalidData:
            return "Invalid keychain data"
        case .unexpectedStatus(let status):
            return "Keychain error: \(status)"
        case .encodingFailed:
            return "Failed to encode data for keychain"
        case .decodingFailed:
            return "Failed to decode data from keychain"
        }
    }
}

/// Manages secure storage in iOS Keychain
class KeychainManager {
    static let shared = KeychainManager()

    private let serviceName = "com.housecall.keychain"

    // Keychain item identifiers
    struct Keys {
        static let masterEncryptionKey = "com.housecall.master-encryption-key"
        static let sessionToken = "com.housecall.session-token"
        static let biometricEnrollment = "com.housecall.biometric-enrollment"
        static let authMethod = "com.housecall.auth-method"
    }

    private init() {}

    // MARK: - Generic Keychain Operations

    /// Saves data to keychain with specified accessibility
    /// - Parameters:
    ///   - data: Data to store
    ///   - key: Unique identifier for the item
    ///   - accessibility: Keychain accessibility level
    func save(data: Data, for key: String, accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly) throws {
        // Delete existing item if present
        try? delete(for: key)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility,
            kSecAttrSynchronizable as String: false // Prevent iCloud sync for security
        ]

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Retrieves data from keychain
    /// - Parameter key: Unique identifier for the item
    /// - Returns: Stored data, or nil if not found
    func retrieve(for key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.unexpectedStatus(status)
        }

        return data
    }

    /// Deletes an item from keychain
    /// - Parameter key: Unique identifier for the item
    func delete(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Master Encryption Key

    /// Saves the master encryption key to keychain
    /// - Parameter key: 256-bit symmetric key
    func saveMasterKey(_ key: SymmetricKey) throws {
        let keyData = key.withUnsafeBytes { Data($0) }
        try save(data: keyData, for: Keys.masterEncryptionKey)
    }

    /// Retrieves the master encryption key from keychain
    /// - Returns: Symmetric key data
    func retrieveMasterKey() throws -> Data? {
        try retrieve(for: Keys.masterEncryptionKey)
    }

    /// Deletes the master encryption key (use with extreme caution - will lose access to encrypted data)
    func deleteMasterKey() throws {
        try delete(for: Keys.masterEncryptionKey)
    }

    // MARK: - Session Token

    /// Saves session token to keychain
    /// - Parameter token: Session UUID
    func saveSessionToken(_ token: UUID) throws {
        let tokenData = Data(token.uuidString.utf8)
        try save(data: tokenData, for: Keys.sessionToken)
    }

    /// Retrieves session token from keychain
    /// - Returns: Session UUID if exists
    func retrieveSessionToken() throws -> UUID? {
        guard let data = try retrieve(for: Keys.sessionToken),
              let tokenString = String(data: data, encoding: .utf8),
              let uuid = UUID(uuidString: tokenString) else {
            return nil
        }
        return uuid
    }

    /// Deletes session token (logout)
    func deleteSessionToken() throws {
        try delete(for: Keys.sessionToken)
    }

    // MARK: - Biometric Enrollment

    /// Saves biometric enrollment status
    /// - Parameter enrolled: Boolean indicating if biometric is enrolled
    func saveBiometricEnrollment(_ enrolled: Bool) throws {
        let data = Data([enrolled ? 1 : 0])
        try save(data: data, for: Keys.biometricEnrollment)
    }

    /// Retrieves biometric enrollment status
    /// - Returns: Boolean indicating enrollment status
    func retrieveBiometricEnrollment() throws -> Bool {
        guard let data = try retrieve(for: Keys.biometricEnrollment),
              let byte = data.first else {
            return false
        }
        return byte == 1
    }

    // MARK: - Authentication Method

    /// Saves user's preferred authentication method
    /// - Parameter method: "password", "passcode", or "biometric"
    func saveAuthMethod(_ method: String) throws {
        let data = Data(method.utf8)
        try save(data: data, for: Keys.authMethod)
    }

    /// Retrieves user's preferred authentication method
    /// - Returns: Authentication method string
    func retrieveAuthMethod() throws -> String? {
        guard let data = try retrieve(for: Keys.authMethod) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Cleanup

    /// Clears all HouseCall keychain items (use with caution)
    func clearAll() throws {
        try? deleteSessionToken()
        try? delete(for: Keys.biometricEnrollment)
        try? delete(for: Keys.authMethod)
        // DO NOT delete master key unless explicitly intended
    }
}
