//
//  PasswordHasherTests.swift
//  HouseCallTests
//
//  Unit tests for PBKDF2 password hashing
//

import Testing
@testable import HouseCall
import Foundation

@Suite("PasswordHasher Tests")
struct PasswordHasherTests {

    // MARK: - Basic Hashing Tests

    @Test("Hash password successfully")
    func testHashPassword() throws {
        let hasher = PasswordHasher.shared
        let password = "SecurePassword123!"

        let hash = try hasher.hash(password: password)

        // Verify hash is not empty
        #expect(hash.count > 0)

        // Hash should be at least: iterations(8) + saltLength(4) + salt(16) + hash(32) = 60 bytes
        #expect(hash.count >= 60)
    }

    @Test("Verify correct password")
    func testVerifyCorrectPassword() throws {
        let hasher = PasswordHasher.shared
        let password = "MySecurePassword456!"

        let hash = try hasher.hash(password: password)
        let isValid = try hasher.verify(password: password, hash: hash)

        #expect(isValid == true)
    }

    @Test("Reject incorrect password")
    func testRejectIncorrectPassword() throws {
        let hasher = PasswordHasher.shared
        let correctPassword = "CorrectPassword789!"
        let wrongPassword = "WrongPassword000!"

        let hash = try hasher.hash(password: correctPassword)
        let isValid = try hasher.verify(password: wrongPassword, hash: hash)

        #expect(isValid == false)
    }

    @Test("Hash output is different for same password (unique salt)")
    func testUniqueSaltPerHash() throws {
        let hasher = PasswordHasher.shared
        let password = "SamePassword123!"

        let hash1 = try hasher.hash(password: password)
        let hash2 = try hasher.hash(password: password)

        // Hashes should be different due to unique salt
        #expect(hash1 != hash2)

        // But both should verify correctly
        #expect(try hasher.verify(password: password, hash: hash1) == true)
        #expect(try hasher.verify(password: password, hash: hash2) == true)
    }

    // MARK: - PBKDF2 Configuration Tests

    @Test("PBKDF2 iterations are correct (600k)")
    func testPBKDF2Iterations() throws {
        let hasher = PasswordHasher.shared
        let password = "TestPassword123!"

        let hash = try hasher.hash(password: password)
        let decoded = try PasswordHash.decode(hash)

        // Verify iterations count
        #expect(decoded.iterations == 600_000)
    }

    @Test("Hash length is 32 bytes (256 bits)")
    func testHashLength() throws {
        let hasher = PasswordHasher.shared
        let password = "TestPassword456!"

        let hash = try hasher.hash(password: password)
        let decoded = try PasswordHash.decode(hash)

        #expect(decoded.hash.count == 32)
    }

    @Test("Salt length is 16 bytes (128 bits)")
    func testSaltLength() throws {
        let hasher = PasswordHasher.shared
        let password = "TestPassword789!"

        let hash = try hasher.hash(password: password)
        let decoded = try PasswordHash.decode(hash)

        #expect(decoded.salt.count == 16)
    }

    // MARK: - Security Tests

    @Test("Constant-time comparison prevents timing attacks")
    func testConstantTimeComparison() throws {
        let hasher = PasswordHasher.shared
        let password1 = "Password1234567!"
        let password2 = "Password1234568!" // Only last char different

        let hash1 = try hasher.hash(password: password1)

        // Time verification of correct password
        let start1 = Date()
        _ = try hasher.verify(password: password1, hash: hash1)
        let time1 = Date().timeIntervalSince(start1)

        // Time verification of wrong password (different at end)
        let start2 = Date()
        _ = try hasher.verify(password: password2, hash: hash1)
        let time2 = Date().timeIntervalSince(start2)

        // Times should be similar (within 10ms tolerance)
        // Note: This is a simplified timing attack test
        let difference = abs(time1 - time2)
        #expect(difference < 0.01) // 10ms tolerance
    }

    @Test("Empty password can be hashed")
    func testEmptyPassword() throws {
        let hasher = PasswordHasher.shared
        let emptyPassword = ""

        let hash = try hasher.hash(password: emptyPassword)
        let isValid = try hasher.verify(password: emptyPassword, hash: hash)

        #expect(isValid == true)
    }

    @Test("Very long password can be hashed")
    func testLongPassword() throws {
        let hasher = PasswordHasher.shared
        let longPassword = String(repeating: "a", count: 1000) + "!1Aa"

        let hash = try hasher.hash(password: longPassword)
        let isValid = try hasher.verify(password: longPassword, hash: hash)

        #expect(isValid == true)
    }

    @Test("Unicode passwords work correctly")
    func testUnicodePasswords() throws {
        let hasher = PasswordHasher.shared
        let unicodePassword = "🔐Pässwörd123!你好"

        let hash = try hasher.hash(password: unicodePassword)
        let isValid = try hasher.verify(password: unicodePassword, hash: hash)

        #expect(isValid == true)
    }

    // MARK: - Encoding/Decoding Tests

    @Test("Encode and decode hash correctly")
    func testEncodeDecodeHash() throws {
        let originalHash = PasswordHash(
            hash: Data([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16,
                       17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32]),
            salt: Data([10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160]),
            iterations: 600_000
        )

        let encoded = originalHash.encode()
        let decoded = try PasswordHash.decode(encoded)

        #expect(decoded.hash == originalHash.hash)
        #expect(decoded.salt == originalHash.salt)
        #expect(decoded.iterations == originalHash.iterations)
    }

    @Test("Decode invalid data throws error")
    func testDecodeInvalidData() throws {
        let invalidData = Data([0x01, 0x02, 0x03]) // Too short

        #expect(throws: PasswordHashError.invalidFormat) {
            try PasswordHash.decode(invalidData)
        }
    }

    @Test("Decode with invalid salt length throws error")
    func testDecodeInvalidSaltLength() throws {
        var invalidData = Data()
        invalidData.append(contentsOf: withUnsafeBytes(of: Int(600_000).bigEndian) { Data($0) })
        invalidData.append(contentsOf: withUnsafeBytes(of: UInt32(1000).bigEndian) { Data($0) }) // Claim 1000 byte salt
        invalidData.append(Data([1, 2, 3])) // But only provide 3 bytes

        #expect(throws: PasswordHashError.invalidFormat) {
            try PasswordHash.decode(invalidData)
        }
    }

    // MARK: - Error Handling Tests

    @Test("Verify with invalid hash data throws error")
    func testVerifyInvalidHashData() throws {
        let hasher = PasswordHasher.shared
        let password = "TestPassword"
        let invalidHash = Data([0x00, 0x01, 0x02])

        #expect(throws: PasswordHashError.self) {
            try hasher.verify(password: password, hash: invalidHash)
        }
    }

    // MARK: - Performance Tests

    @Test("Hashing takes reasonable time (200-500ms for PBKDF2)")
    func testHashingPerformance() throws {
        let hasher = PasswordHasher.shared
        let password = "PerformanceTestPassword123!"

        let start = Date()
        _ = try hasher.hash(password: password)
        let elapsed = Date().timeIntervalSince(start)

        // PBKDF2 with 600k iterations should take 200-500ms on modern hardware
        // Allow up to 1 second for slower CI environments
        #expect(elapsed < 1.0)
        #expect(elapsed > 0.05) // Should be slow enough to be secure
    }

    @Test("Verification takes reasonable time")
    func testVerificationPerformance() throws {
        let hasher = PasswordHasher.shared
        let password = "VerifyPerformanceTest123!"

        let hash = try hasher.hash(password: password)

        let start = Date()
        _ = try hasher.verify(password: password, hash: hash)
        let elapsed = Date().timeIntervalSince(start)

        // Verification should take similar time to hashing
        #expect(elapsed < 1.0)
    }

    // MARK: - Edge Cases

    @Test("Case sensitive password verification")
    func testCaseSensitivity() throws {
        let hasher = PasswordHasher.shared
        let password = "Password123!"
        let differentCase = "password123!"

        let hash = try hasher.hash(password: password)

        #expect(try hasher.verify(password: password, hash: hash) == true)
        #expect(try hasher.verify(password: differentCase, hash: hash) == false)
    }

    @Test("Whitespace matters in password")
    func testWhitespaceSensitivity() throws {
        let hasher = PasswordHasher.shared
        let password = "Password 123!"
        let noSpace = "Password123!"

        let hash = try hasher.hash(password: password)

        #expect(try hasher.verify(password: password, hash: hash) == true)
        #expect(try hasher.verify(password: noSpace, hash: hash) == false)
    }

    @Test("Password with only special characters")
    func testSpecialCharactersOnly() throws {
        let hasher = PasswordHasher.shared
        let password = "!@#$%^&*()_+-=[]{}|;:,.<>?"

        let hash = try hasher.hash(password: password)
        let isValid = try hasher.verify(password: password, hash: hash)

        #expect(isValid == true)
    }
}
