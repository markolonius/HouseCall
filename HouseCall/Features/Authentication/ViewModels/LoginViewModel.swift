//
//  LoginViewModel.swift
//  HouseCall
//
//  ViewModel for user login
//

import Foundation
import SwiftUI

@MainActor
class LoginViewModel: ObservableObject {
    @Published var email: String = ""
    @Published var credential: String = "" // Password or passcode
    @Published var authMethod: AuthMethod = .password

    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isLoginSuccessful: Bool = false

    @Published var useBiometric: Bool = false
    @Published var biometricType: BiometricType = .none

    private let authService: AuthenticationService
    private let biometricAuthManager: BiometricAuthManager

    init(
        authService: AuthenticationService = .shared,
        biometricAuthManager: BiometricAuthManager = .shared
    ) {
        self.authService = authService
        self.biometricAuthManager = biometricAuthManager

        // Check biometric availability
        self.biometricType = biometricAuthManager.isBiometricAvailable()
        self.useBiometric = biometricAuthManager.isBiometricEnabledForApp() && biometricType != .none
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
