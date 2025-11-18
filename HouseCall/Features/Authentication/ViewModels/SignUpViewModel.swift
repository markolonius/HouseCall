//
//  SignUpViewModel.swift
//  HouseCall
//
//  ViewModel for user registration
//

import Foundation
import SwiftUI

@MainActor
class SignUpViewModel: ObservableObject {
    @Published var email: String = ""
    @Published var password: String = ""
    @Published var confirmPassword: String = ""
    @Published var fullName: String = ""
    @Published var authMethod: AuthMethod = .password

    @Published var emailError: String?
    @Published var passwordError: String?
    @Published var confirmPasswordError: String?
    @Published var fullNameError: String?

    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isRegistrationSuccessful: Bool = false

    @Published var passwordStrength: Int = 0

    private let authService: AuthenticationService

    init(authService: AuthenticationService = .shared) {
        self.authService = authService
    }

    // MARK: - Real-time Validation

    func validateEmail() {
        let result = Validators.validateEmail(email)
        emailError = result.isValid ? nil : result.errorMessage
    }

    func validatePassword() {
        let result = Validators.validatePassword(password)
        passwordError = result.isValid ? nil : result.errorMessage

        // Update strength indicator
        passwordStrength = Validators.assessPasswordStrength(password)
    }

    func validateConfirmPassword() {
        let result = Validators.validatePasswordConfirmation(
            password: password,
            confirmation: confirmPassword
        )
        confirmPasswordError = result.isValid ? nil : result.errorMessage
    }

    func validateFullName() {
        let result = Validators.validateFullName(fullName)
        fullNameError = result.isValid ? nil : result.errorMessage
    }

    // MARK: - Sign Up

    func signUp() async {
        // Validate all fields
        validateEmail()
        validatePassword()
        validateConfirmPassword()
        validateFullName()

        // Check for errors
        guard emailError == nil,
              passwordError == nil,
              confirmPasswordError == nil,
              fullNameError == nil else {
            errorMessage = "Please fix the errors above"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            _ = try await authService.register(
                email: email,
                password: authMethod == .password ? password : nil,
                passcode: authMethod == .passcode ? password : nil, // Using password field for passcode
                fullName: fullName,
                authMethod: authMethod
            )

            isRegistrationSuccessful = true
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Helper Methods

    var canSubmit: Bool {
        !email.isEmpty &&
        !password.isEmpty &&
        !confirmPassword.isEmpty &&
        !fullName.isEmpty &&
        !isLoading
    }

    var passwordStrengthText: String {
        Validators.passwordStrengthDescription(for: passwordStrength)
    }

    var passwordStrengthColor: Color {
        switch passwordStrength {
        case 0...1: return .red
        case 2: return .orange
        case 3: return .yellow
        case 4: return .green
        case 5: return .blue
        default: return .gray
        }
    }
}
