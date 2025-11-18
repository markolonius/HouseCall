//
//  BiometricAuthManagerTests.swift
//  HouseCallTests
//
//  Unit tests for Biometric Authentication Manager
//

import Testing
import LocalAuthentication
@testable import HouseCall

@Suite("BiometricAuthManager Tests")
struct BiometricAuthManagerTests {

    // MARK: - Biometric Type Tests

    @Test("Biometric type display names")
    func testBiometricTypeDisplayNames() {
        #expect(BiometricType.faceID.displayName == "Face ID")
        #expect(BiometricType.touchID.displayName == "Touch ID")
        #expect(BiometricType.none.displayName == "None")
    }

    // MARK: - Error Handling Tests

    @Test("BiometricAuthError descriptions are user-friendly")
    func testErrorDescriptions() {
        #expect(BiometricAuthError.notAvailable.errorDescription != nil)
        #expect(BiometricAuthError.notEnrolled.errorDescription != nil)
        #expect(BiometricAuthError.userCancel.errorDescription != nil)
        #expect(BiometricAuthError.passcodeNotSet.errorDescription != nil)
    }

    @Test("User cancel error allows retry")
    func testUserCancelAllowsRetry() {
        #expect(BiometricAuthError.userCancel.shouldRetry == true)
        #expect(BiometricAuthError.userFallback.shouldRetry == true)
    }

    @Test("Lockout error does not allow retry")
    func testLockoutDoesNotAllowRetry() {
        #expect(BiometricAuthError.biometricLockout.shouldRetry == false)
    }

    // MARK: - Authentication Result Tests

    @Test("Success result creation")
    func testSuccessResult() {
        let result = BiometricAuthResult.success()
        #expect(result.success == true)
        #expect(result.error == nil)
        #expect(result.canRetry == false)
    }

    @Test("Failure result creation")
    func testFailureResult() {
        let result = BiometricAuthResult.failure(.userCancel)
        #expect(result.success == false)
        #expect(result.error != nil)
        #expect(result.canRetry == true) // User cancel allows retry
    }

    // MARK: - Authentication Reason Tests

    @Test("Healthcare-appropriate authentication reasons")
    func testAuthenticationReasons() {
        let loginReason = BiometricAuthManager.createAuthenticationReason(for: "login")
        #expect(loginReason.contains("health information"))

        let accessReason = BiometricAuthManager.createAuthenticationReason(for: "access")
        #expect(accessReason.contains("health data"))

        let updateReason = BiometricAuthManager.createAuthenticationReason(for: "update")
        #expect(updateReason.contains("health information"))

        let defaultReason = BiometricAuthManager.createAuthenticationReason(for: "unknown")
        #expect(defaultReason.contains("HouseCall"))
    }

    // MARK: - Biometric Enrollment Tests

    @Test("Enable biometric auth saves to keychain")
    func testEnableBiometricAuth() throws {
        let keychainManager = KeychainManager.shared
        let manager = BiometricAuthManager(
            context: LAContext(),
            keychainManager: keychainManager
        )

        try manager.enableBiometricAuth()

        let isEnabled = try keychainManager.retrieveBool(for: "BiometricAuthEnabled")
        #expect(isEnabled == true)

        // Cleanup
        try? keychainManager.delete(for: "BiometricAuthEnabled")
    }

    @Test("Disable biometric auth removes from keychain")
    func testDisableBiometricAuth() throws {
        let keychainManager = KeychainManager.shared
        let manager = BiometricAuthManager(
            context: LAContext(),
            keychainManager: keychainManager
        )

        // First enable
        try manager.enableBiometricAuth()
        #expect(try keychainManager.retrieveBool(for: "BiometricAuthEnabled") == true)

        // Then disable
        try manager.disableBiometricAuth()
        let isEnabled = try keychainManager.retrieveBool(for: "BiometricAuthEnabled")
        #expect(isEnabled == nil)
    }

    @Test("Check biometric enabled status")
    func testIsBiometricEnabledForApp() throws {
        let keychainManager = KeychainManager.shared
        let manager = BiometricAuthManager(
            context: LAContext(),
            keychainManager: keychainManager
        )

        // Initially should be false
        #expect(manager.isBiometricEnabledForApp() == false)

        // Enable and check
        try manager.enableBiometricAuth()
        #expect(manager.isBiometricEnabledForApp() == true)

        // Cleanup
        try? manager.disableBiometricAuth()
    }

    // MARK: - Integration Notes

    // Note: Full integration tests for biometric authentication require physical device
    // as iOS Simulator doesn't support Face ID/Touch ID authentication flows.
    // These tests verify the logic layer and can be supplemented with UI tests on device.
}
