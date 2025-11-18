//
//  PasswordHasher.swift
//  HouseCall
//
//  Secure password hashing using PBKDF2
//  NOTE: Production HIPAA implementation should use bcrypt via Swift Package Manager
//  Using PBKDF2 as interim solution with high iteration count
//

import Foundation
import CryptoKit

/// Errors that can occur during password hashing
enum PasswordHashError: LocalizedError {
    case hashingFailed
    case verificationFailed
    case invalidFormat
    case invalidData

    var errorDescription: String? {
        switch self {
        case .hashingFailed:
            return "Failed to hash password"
        case .verificationFailed:
            return "Failed to verify password"
        case .invalidFormat:
            return "Invalid password hash format"
        case .invalidData:
            return "Invalid password data"
        }
    }
}

/// Password hash result containing hash and salt
struct PasswordHash {
    let hash: Data
    let salt: Data
    let iterations: Int

    /// Encodes hash to storable format
    func encode() -> Data {
        var result = Data()
        result.append(contentsOf: withUnsafeBytes(of: iterations.bigEndian) { Data($0) })
        result.append(contentsOf: withUnsafeBytes(of: UInt32(salt.count).bigEndian) { Data($0) })
        result.append(salt)
        result.append(hash)
        return result
    }

    /// Decodes hash from stored format
    static func decode(_ data: Data) throws -> PasswordHash {
        guard data.count > 12 else {
            throw PasswordHashError.invalidFormat
        }

        var offset = 0

        // Read iterations (8 bytes)
        let iterations = data.subdata(in: offset..<offset+8).withUnsafeBytes {
            Int(bigEndian: $0.load(as: Int.self))
        }
        offset += 8

        // Read salt length (4 bytes)
        let saltLength = Int(data.subdata(in: offset..<offset+4).withUnsafeBytes {
            UInt32(bigEndian: $0.load(as: UInt32.self))
        })
        offset += 4

        // Read salt
        guard data.count >= offset + saltLength else {
            throw PasswordHashError.invalidFormat
        }
        let salt = data.subdata(in: offset..<offset+saltLength)
        offset += saltLength

        // Read hash (remaining bytes)
        let hash = data.subdata(in: offset..<data.count)

        return PasswordHash(hash: hash, salt: salt, iterations: iterations)
    }
}

/// Manages secure password hashing and verification
class PasswordHasher {
    static let shared = PasswordHasher()

    // PBKDF2 configuration (high iteration count for security)
    // NOTE: Bcrypt with cost factor 12 is preferred for production
    private let iterations = 600_000 // OWASP recommended minimum for PBKDF2-SHA256
    private let hashLength = 32 // 256 bits
    private let saltLength = 16 // 128 bits

    private init() {}

    /// Hashes a password using PBKDF2-SHA256
    /// - Parameter password: Plaintext password
    /// - Returns: Encoded hash data containing salt and hash
    func hash(password: String) throws -> Data {
        guard let passwordData = password.data(using: .utf8) else {
            throw PasswordHashError.invalidData
        }

        // Generate random salt
        var salt = Data(count: saltLength)
        let result = salt.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, saltLength, $0.baseAddress!)
        }

        guard result == errSecSuccess else {
            throw PasswordHashError.hashingFailed
        }

        // Derive key using PBKDF2
        let hash = try deriveKey(from: passwordData, salt: salt, iterations: iterations)

        let passwordHash = PasswordHash(hash: hash, salt: salt, iterations: iterations)
        return passwordHash.encode()
    }

    /// Verifies a password against a stored hash
    /// - Parameters:
    ///   - password: Plaintext password to verify
    ///   - hashData: Stored hash data
    /// - Returns: True if password matches
    func verify(password: String, hash hashData: Data) throws -> Bool {
        guard let passwordData = password.data(using: .utf8) else {
            throw PasswordHashError.invalidData
        }

        // Decode stored hash
        let storedHash = try PasswordHash.decode(hashData)

        // Derive key with same parameters
        let computedHash = try deriveKey(
            from: passwordData,
            salt: storedHash.salt,
            iterations: storedHash.iterations
        )

        // Constant-time comparison to prevent timing attacks
        return constantTimeCompare(computedHash, storedHash.hash)
    }

    // MARK: - Private Helpers

    /// Derives a key using PBKDF2-SHA256
    private func deriveKey(from password: Data, salt: Data, iterations: Int) throws -> Data {
        var derivedKeyData = Data(repeating: 0, count: hashLength)

        let derivationStatus = derivedKeyData.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        hashLength
                    )
                }
            }
        }

        guard derivationStatus == kCCSuccess else {
            throw PasswordHashError.hashingFailed
        }

        return derivedKeyData
    }

    /// Constant-time comparison to prevent timing attacks
    private func constantTimeCompare(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }

        var result: UInt8 = 0
        for (byte1, byte2) in zip(lhs, rhs) {
            result |= byte1 ^ byte2
        }

        return result == 0
    }

    // MARK: - Secure Memory Cleanup

    /// Securely zeros out password string from memory
    func zeroPassword(_ password: inout String) {
        password = String(repeating: "\0", count: password.count)
        password = ""
    }
}

// Import CommonCrypto for PBKDF2
import CommonCrypto
