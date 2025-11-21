//
//  LoginViewModel.swift
//  HouseCall
//
//  ViewModel for user login
//

import Foundation
import SwiftUI

@MainActor
@Observable
class LoginViewModel {
    var email: String = ""
    var credential: String = "" // Password or passcode
    var authMethod: AuthMethod = .password

    var isLoading: Bool = false
    var errorMessage: String?
    var isLoginSuccessful: Bool = false

    var useBiometric: Bool = false
    var biometricType: BiometricType = .none

    private let authService: AuthenticationService
    private let biometricAuthManager: BiometricAuthManager

    init(
        authService: AuthenticationService? = nil,
        biometricAuthManager: BiometricAuthManager? = nil
    ) {
        self.authService = authService ?? .shared
        self.biometricAuthManager = biometricAuthManager ?? .shared

        // Check biometric availability
        self.biometricType = self.biometricAuthManager.isBiometricAvailable()
        self.useBiometric = self.biometricAuthManager.isBiometricEnabledForApp() && biometricType != .none
    }

    // MARK: - Login

    func login() async {
        isLoading = true
        errorMessage = nil

        do {
            if useBiometric && biometricType != .none {
                _ = try await authService.loginWithBiometric(email: email)
            } else {
                _ = try await authService.login(
                    email: email,
                    credential: credential,
                    authMethod: authMethod,
                    useBiometric: false
                )
            }

            isLoginSuccessful = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Helper Methods

    var canSubmit: Bool {
        if useBiometric {
            return !email.isEmpty && !isLoading
        } else {
            return !email.isEmpty && !credential.isEmpty && !isLoading
        }
    }

    var credentialPlaceholder: String {
        switch authMethod {
        case .password: return "Password"
        case .passcode: return "6-Digit Passcode"
        case .biometric: return ""
        }
    }

    var biometricIconName: String {
        switch biometricType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .none: return ""
        }
    }
}
