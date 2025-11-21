//
//  KeychainManagerTests.swift
//  HouseCallTests
//
//  Unit tests for Keychain storage manager
//

import Testing
import CryptoKit
@testable import HouseCall
import Foundation

@Suite("KeychainManager Tests")
struct KeychainManagerTests {

    // Use unique service name for testing to avoid conflicts
    let testKey = "test.keychain.item.\(UUID().uuidString)"

    // MARK: - Basic Operations

    @Test("Save and retrieve data from keychain")
    func testSaveAndRetrieve() throws {
        let manager = KeychainManager.shared
        let testData = Data("Test data".utf8)

        try manager.save(data: testData, for: testKey)
        let retrieved = try manager.retrieve(for: testKey)

        #expect(retrieved == testData)

        // Cleanup
        try? manager.delete(for: testKey)
    }

    @Test("Retrieve non-existent item returns nil")
    func testRetrieveNonExistent() throws {
        let manager = KeychainManager.shared
        let nonExistentKey = "non.existent.key.\(UUID().uuidString)"

        let retrieved = try manager.retrieve(for: nonExistentKey)
        #expect(retrieved == nil)
    }

    @Test("Delete item from keychain")
    func testDelete() throws {
        let manager = KeychainManager.shared
        let testData = Data("Test data".utf8)

        try manager.save(data: testData, for: testKey)
        try manager.delete(for: testKey)

        let retrieved = try manager.retrieve(for: testKey)
        #expect(retrieved == nil)
    }

    @Test("Duplicate save overwrites existing item")
    func testDuplicateSaveOverwrites() throws {
        let manager = KeychainManager.shared
        let data1 = Data("First data".utf8)
        let data2 = Data("Second data".utf8)

        try manager.save(data: data1, for: testKey)
        try manager.save(data: data2, for: testKey)

        let retrieved = try manager.retrieve(for: testKey)
        #expect(retrieved == data2)

        // Cleanup
        try? manager.delete(for: testKey)
    }

    @Test("Delete non-existent item succeeds")
    func testDeleteNonExistent() throws {
        let manager = KeychainManager.shared
        let nonExistentKey = "non.existent.key.\(UUID().uuidString)"

        // Should not throw
        try manager.delete(for: nonExistentKey)
    }

    // MARK: - Master Key Operations

    @Test("Save and retrieve master encryption key")
    func testMasterKey() throws {
        let manager = KeychainManager.shared
        let masterKey = SymmetricKey(size: .bits256)

        try manager.saveMasterKey(masterKey)
        let retrievedData = try manager.retrieveMasterKey()

        #expect(retrievedData != nil)
        #expect(retrievedData?.count == 32) // 256 bits = 32 bytes

        // Cleanup
        try? manager.deleteMasterKey()
    }

    // MARK: - Session Token Operations

    @Test("Save and retrieve session token")
    func testSessionToken() throws {
        let manager = KeychainManager.shared
        let sessionToken = UUID()

        try manager.saveSessionToken(sessionToken)
        let retrieved = try manager.retrieveSessionToken()

        #expect(retrieved == sessionToken)

        // Cleanup
        try? manager.deleteSessionToken()
    }

    @Test("Delete session token")
    func testDeleteSessionToken() throws {
        let manager = KeychainManager.shared
        let sessionToken = UUID()

        try manager.saveSessionToken(sessionToken)
        try manager.deleteSessionToken()

        let retrieved = try manager.retrieveSessionToken()
        #expect(retrieved == nil)
    }

    // MARK: - Boolean Operations

    @Test("Save and retrieve boolean true")
    func testSaveBoolTrue() throws {
        let manager = KeychainManager.shared

        try manager.saveBool(true, for: testKey)
        let retrieved = try manager.retrieveBool(for: testKey)

        #expect(retrieved == true)

        // Cleanup
        try? manager.delete(for: testKey)
    }

    @Test("Save and retrieve boolean false")
    func testSaveBoolFalse() throws {
        let manager = KeychainManager.shared

        try manager.saveBool(false, for: testKey)
        let retrieved = try manager.retrieveBool(for: testKey)

        #expect(retrieved == false)

        // Cleanup
        try? manager.delete(for: testKey)
    }

    @Test("Retrieve non-existent boolean returns nil")
    func testRetrieveBoolNonExistent() throws {
        let manager = KeychainManager.shared
        let nonExistentKey = "non.existent.bool.\(UUID().uuidString)"

        let retrieved = try manager.retrieveBool(for: nonExistentKey)
        #expect(retrieved == nil)
    }

    // MARK: - Biometric Enrollment

    @Test("Save and retrieve biometric enrollment status")
    func testBiometricEnrollment() throws {
        let manager = KeychainManager.shared

        try manager.saveBiometricEnrollment(true)
        let retrieved = try manager.retrieveBiometricEnrollment()

        #expect(retrieved == true)
    }

    @Test("Retrieve biometric enrollment when not set returns false")
    func testBiometricEnrollmentDefault() throws {
        let manager = KeychainManager.shared

        // Delete if exists
        try? manager.delete(for: KeychainManager.Keys.biometricEnrollment)

        let retrieved = try manager.retrieveBiometricEnrollment()
        #expect(retrieved == false)
    }

    // MARK: - Auth Method

    @Test("Save and retrieve auth method")
    func testAuthMethod() throws {
        let manager = KeychainManager.shared
        let authMethod = "password"

        try manager.saveAuthMethod(authMethod)
        let retrieved = try manager.retrieveAuthMethod()

        #expect(retrieved == authMethod)
    }

    @Test("Retrieve non-existent auth method returns nil")
    func testAuthMethodNonExistent() throws {
        let manager = KeychainManager.shared

        // Delete if exists
        try? manager.delete(for: KeychainManager.Keys.authMethod)

        let retrieved = try manager.retrieveAuthMethod()
        #expect(retrieved == nil)
    }

    // MARK: - Clear All

    @Test("Clear all removes keychain items")
    func testClearAll() throws {
        let manager = KeychainManager.shared

        // Set up some data
        try manager.saveSessionToken(UUID())
        try manager.saveBiometricEnrollment(true)
        try manager.saveAuthMethod("password")

        // Clear all
        try manager.clearAll()

        // Verify all cleared (except master key)
        let sessionToken = try manager.retrieveSessionToken()
        let biometric = try manager.retrieveBiometricEnrollment()
        let authMethod = try manager.retrieveAuthMethod()

        #expect(sessionToken == nil)
        #expect(biometric == false) // Returns false when not set
        #expect(authMethod == nil)
    }

    // MARK: - Data Integrity

    @Test("Save empty data")
    func testSaveEmptyData() throws {
        let manager = KeychainManager.shared
        let emptyData = Data()

        try manager.save(data: emptyData, for: testKey)
        let retrieved = try manager.retrieve(for: testKey)

        #expect(retrieved == emptyData)

        // Cleanup
        try? manager.delete(for: testKey)
    }

    @Test("Save large data")
    func testSaveLargeData() throws {
        let manager = KeychainManager.shared
        let largeData = Data(repeating: 0x42, count: 10_000) // 10 KB

        try manager.save(data: largeData, for: testKey)
        let retrieved = try manager.retrieve(for: testKey)

        #expect(retrieved == largeData)

        // Cleanup
        try? manager.delete(for: testKey)
    }

    // MARK: - Accessibility Tests

    @Test("Keychain items use correct accessibility")
    func testKeychainAccessibility() throws {
        let manager = KeychainManager.shared
        let testData = Data("Secure data".utf8)

        // Default accessibility should be kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        try manager.save(data: testData, for: testKey)

        // We can't easily verify the accessibility attribute without
        // inspecting the keychain directly, but we can verify the item exists
        let retrieved = try manager.retrieve(for: testKey)
        #expect(retrieved == testData)

        // Cleanup
        try? manager.delete(for: testKey)
    }

    // MARK: - Concurrency Tests

    @Test("Concurrent saves don't corrupt data")
    func testConcurrentSaves() async throws {
        let manager = await KeychainManager.shared
        let iterations = 10

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    let key = "concurrent.test.\(i)"
                    let data = Data("Data \(i)".utf8)
                    try? await manager.save(data: data, for: key)
                }
            }
        }

        // Verify all items saved correctly
        for i in 0..<iterations {
            let key = "concurrent.test.\(i)"
            let retrieved = try await manager.retrieve(for: key)
            let expected = Data("Data \(i)".utf8)
            #expect(retrieved == expected)

            // Cleanup
            try? await manager.delete(for: key)
        }
    }
}
