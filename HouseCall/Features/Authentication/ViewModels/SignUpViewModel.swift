//
//  SignUpViewModel.swift
//  HouseCall
//
//  ViewModel for user registration
//

import Foundation
import SwiftUI
import Combine

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
        print("🔐 Password validation - Length: \(password.count), Strength: \(passwordStrength), Error: \(passwordError ?? "none")")
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

    func signUp() async -> Bool {
        print("📝 Sign up started - Email: \(email), Name: \(fullName), Password length: \(password.count)")

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
            print("❌ Validation failed - Email: \(emailError ?? "ok"), Password: \(passwordError ?? "ok"), Confirm: \(confirmPasswordError ?? "ok"), Name: \(fullNameError ?? "ok")")
            await MainActor.run {
                errorMessage = "Please fix the errors above"
            }
            return false
        }

        print("✅ All validations passed, attempting registration...")

        errorMessage = nil

        var success = false
        do {
            print("🔄 Calling authService.register...")
            _ = try await authService.register(
                email: email,
                password: authMethod == .password ? password : nil,
                passcode: authMethod == .passcode ? password : nil,
                fullName: fullName,
                authMethod: authMethod
            )

            print("✅ Registration successful!")
            success = true
        } catch {
            print("❌ Registration failed: \(error)")
            errorMessage = error.localizedDescription
        }

        print("🏁 Sign up completed")
        return success
    }

    // MARK: - Helper Methods

    var canSubmit: Bool {
        !email.isEmpty &&
        !password.isEmpty &&
        !confirmPassword.isEmpty &&
        !fullName.isEmpty
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
