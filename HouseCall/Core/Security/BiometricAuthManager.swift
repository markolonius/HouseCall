//
//  BiometricAuthManager.swift
//  HouseCall
//
//  Biometric Authentication Manager using LocalAuthentication
//  Supports Face ID and Touch ID for secure healthcare data access
//

import Foundation
import LocalAuthentication

/// Types of biometric authentication available on the device
enum BiometricType {
    case faceID
    case touchID
    case none

    var displayName: String {
        switch self {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .none: return "None"
        }
    }
}

/// Errors that can occur during biometric authentication
enum BiometricAuthError: LocalizedError {
    case notAvailable
    case notEnrolled
    case userCancel
    case userFallback
    case systemCancel
    case passcodeNotSet
    case biometricLockout
    case failed(String)
    case unknown(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Biometric authentication is not available on this device"
        case .notEnrolled:
            return "No biometric authentication is enrolled. Please set up Face ID or Touch ID in Settings"
        case .userCancel:
            return "Authentication was cancelled"
        case .userFallback:
            return "User chose to enter password instead"
        case .systemCancel:
            return "Authentication was cancelled by the system"
        case .passcodeNotSet:
            return "Device passcode is not set. Please set a passcode in Settings to enable biometric authentication"
        case .biometricLockout:
            return "Biometric authentication is locked due to too many failed attempts. Please try again later"
        case .failed(let reason):
            return "Authentication failed: \(reason)"
        case .unknown(let error):
            return "An unknown error occurred: \(error.localizedDescription)"
        }
    }

    var shouldRetry: Bool {
        switch self {
        case .userCancel, .userFallback:
            return true
        case .biometricLockout:
            return false
        default:
            return false
        }
    }
}

/// Result of biometric authentication attempt
struct BiometricAuthResult {
    let success: Bool
    let error: BiometricAuthError?
    let canRetry: Bool

    static func success() -> BiometricAuthResult {
        return BiometricAuthResult(success: true, error: nil, canRetry: false)
    }

    static func failure(_ error: BiometricAuthError) -> BiometricAuthResult {
        return BiometricAuthResult(success: false, error: error, canRetry: error.shouldRetry)
    }
}

/// Manages biometric authentication for the HouseCall app
class BiometricAuthManager {
    static let shared = BiometricAuthManager()

    private let context: LAContext
    private let keychainManager: KeychainManager

    init(
        context: LAContext = LAContext(),
        keychainManager: KeychainManager = .shared
    ) {
        self.context = context
        self.keychainManager = keychainManager
    }

    // MARK: - Biometric Availability

    /// Checks if biometric authentication is available and returns the type
    /// - Returns: BiometricType indicating Face ID, Touch ID, or none
    func isBiometricAvailable() -> BiometricType {
        var error: NSError?

        // Check if biometric authentication is available
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }

        // Determine the type of biometric authentication
        switch context.biometryType {
        case .faceID:
            return .faceID
        case .touchID:
            return .touchID
        case .none:
            return .none
        case .opticID:
            return .faceID // Optic ID on Vision Pro, treat similarly to Face ID
        @unknown default:
            return .none
        }
    }

    /// Checks if biometric authentication is enrolled and ready to use
    /// - Returns: true if biometrics are enrolled, false otherwise
    func isBiometricEnrolled() -> Bool {
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    /// Gets a user-friendly description of why biometrics are not available
    /// - Returns: Error description or nil if biometrics are available
    func biometricUnavailabilityReason() -> String? {
        var error: NSError?

        guard !context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return nil
        }

        guard let laError = error else {
            return "Biometric authentication is not available"
        }

        switch LAError.Code(rawValue: laError.code) {
        case .biometryNotAvailable:
            return "This device does not support biometric authentication"
        case .biometryNotEnrolled:
            return "No biometric authentication is set up. Please configure Face ID or Touch ID in Settings"
        case .passcodeNotSet:
            return "Device passcode is required. Please set a passcode in Settings"
        case .biometryLockout:
            return "Biometric authentication is locked. Please unlock your device"
        default:
            return laError.localizedDescription
        }
    }

    // MARK: - Authentication

    /// Authenticates the user using biometric authentication
    /// - Parameters:
    ///   - reason: The reason for authentication shown to the user
    ///   - completion: Callback with the result of authentication
    func authenticate(reason: String, completion: @escaping (BiometricAuthResult) -> Void) {
        // Create a fresh context for each authentication attempt
        let authContext = LAContext()
        authContext.localizedCancelTitle = "Cancel"
        authContext.localizedFallbackTitle = "Use Password"

        // Check if biometric authentication is available
        var error: NSError?
        guard authContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            if let laError = error {
                let biometricError = mapLAError(laError)
                completion(.failure(biometricError))
            } else {
                completion(.failure(.notAvailable))
            }
            return
        }

        // Perform biometric authentication
        authContext.evaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            localizedReason: reason
        ) { success, error in
            DispatchQueue.main.async {
                if success {
                    completion(.success())
                } else if let error = error {
                    let biometricError = self.mapLAError(error as NSError)
                    completion(.failure(biometricError))
                } else {
                    completion(.failure(.failed("Unknown authentication error")))
                }
            }
        }
    }

    /// Authenticates the user with async/await support
    /// - Parameter reason: The reason for authentication shown to the user
    /// - Returns: BiometricAuthResult
    @available(iOS 15.0, *)
    func authenticate(reason: String) async -> BiometricAuthResult {
        await withCheckedContinuation { continuation in
            authenticate(reason: reason) { result in
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - Biometric Enrollment

    /// Checks if the user has enabled biometric authentication for the app
    /// - Returns: true if biometric auth is enabled for this app
    func isBiometricEnabledForApp() -> Bool {
        do {
            return try keychainManager.retrieveBool(for: "BiometricAuthEnabled") ?? false
        } catch {
            return false
        }
    }

    /// Enables biometric authentication for the app
    /// - Throws: KeychainError if saving fails
    func enableBiometricAuth() throws {
        try keychainManager.saveBool(true, for: "BiometricAuthEnabled")
    }

    /// Disables biometric authentication for the app
    /// - Throws: KeychainError if deletion fails
    func disableBiometricAuth() throws {
        try keychainManager.delete(for: "BiometricAuthEnabled")
    }

    // MARK: - Helper Methods

    /// Maps LAError to BiometricAuthError
    /// - Parameter error: LAError from LocalAuthentication
    /// - Returns: BiometricAuthError
    private func mapLAError(_ error: NSError) -> BiometricAuthError {
        guard let laErrorCode = LAError.Code(rawValue: error.code) else {
            return .unknown(error)
        }

        switch laErrorCode {
        case .userCancel:
            return .userCancel
        case .userFallback:
            return .userFallback
        case .systemCancel:
            return .systemCancel
        case .passcodeNotSet:
            return .passcodeNotSet
        case .biometryNotAvailable:
            return .notAvailable
        case .biometryNotEnrolled:
            return .notEnrolled
        case .biometryLockout:
            return .biometricLockout
        case .authenticationFailed:
            return .failed("Biometric authentication failed")
        case .invalidContext:
            return .failed("Invalid authentication context")
        case .notInteractive:
            return .failed("Authentication cannot be performed in non-interactive mode")
        case .appCancel:
            return .systemCancel
        case .touchIDNotAvailable:
            return .notAvailable
        case .touchIDNotEnrolled:
            return .notEnrolled
        case .touchIDLockout:
            return .biometricLockout
        case .invalidDimensions:
            return .failed("Invalid dimensions")
        #if os(watchOS)
        case .watchNotAvailable:
            return .notAvailable
        #endif
        #if os(iOS)
        case .companionNotAvailable:
            return .notAvailable
        #endif
        @unknown default:
            return .unknown(error)
        }
    }

    /// Creates a healthcare-appropriate authentication reason string
    /// - Parameter action: The action being performed (e.g., "login", "access health data")
    /// - Returns: User-friendly reason string
    static func createAuthenticationReason(for action: String) -> String {
        switch action.lowercased() {
        case "login":
            return "Authenticate to access your HouseCall account and health information"
        case "access":
            return "Authenticate to view your health data and medical records"
        case "update":
            return "Authenticate to update your health information"
        case "message":
            return "Authenticate to access your healthcare communications"
        default:
            return "Authenticate to continue with HouseCall"
        }
    }
}
