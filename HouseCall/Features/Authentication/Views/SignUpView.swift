//
//  SignUpView.swift
//  HouseCall
//
//  User registration view with real-time validation
//

import SwiftUI

struct SignUpView: View {
    @StateObject private var viewModel = SignUpViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Text("Create Account")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Secure your health information with HouseCall")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    // Form Fields
                    VStack(spacing: 20) {
                        // Full Name
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Full Name")
                                .font(.headline)

                            TextField("First and Last Name", text: $viewModel.fullName)
                                .textContentType(.name)
                                .autocapitalization(.words)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: viewModel.fullName) { _ in
                                    viewModel.validateFullName()
                                }

                            if let error = viewModel.fullNameError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        // Email
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Email Address")
                                .font(.headline)

                            TextField("email@example.com", text: $viewModel.email)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: viewModel.email) { _ in
                                    viewModel.validateEmail()
                                }

                            if let error = viewModel.emailError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        // Password
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Password")
                                .font(.headline)

                            SecureField("Minimum 12 characters", text: $viewModel.password)
                                .textContentType(.newPassword)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: viewModel.password) { _ in
                                    viewModel.validatePassword()
                                }

                            // Password strength indicator
                            if !viewModel.password.isEmpty {
                                HStack {
                                    Text("Strength:")
                                        .font(.caption)

                                    Text(viewModel.passwordStrengthText)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(viewModel.passwordStrengthColor)

                                    Spacer()
                                }
                            }

                            if let error = viewModel.passwordError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                        }

                        // Confirm Password
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Confirm Password")
                                .font(.headline)

                            SecureField("Re-enter password", text: $viewModel.confirmPassword)
                                .textContentType(.newPassword)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                                .onChange(of: viewModel.confirmPassword) { _ in
                                    viewModel.validateConfirmPassword()
                                }

                            if let error = viewModel.confirmPasswordError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else if !viewModel.confirmPassword.isEmpty &&
                                      viewModel.password == viewModel.confirmPassword {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                    Text("Passwords match")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }
                        }

                        // Password Requirements
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Password must contain:")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            RequirementRow(text: "At least 12 characters", met: viewModel.password.count >= 12)
                            RequirementRow(text: "Uppercase letter", met: viewModel.password.range(of: "[A-Z]", options: .regularExpression) != nil)
                            RequirementRow(text: "Lowercase letter", met: viewModel.password.range(of: "[a-z]", options: .regularExpression) != nil)
                            RequirementRow(text: "Number", met: viewModel.password.range(of: "[0-9]", options: .regularExpression) != nil)
                            RequirementRow(text: "Special character", met: viewModel.password.range(of: "[!@#$%^&*()_+\\-=\\[\\]{}|;:,.<>?]", options: .regularExpression) != nil)
                        }
                        .padding(.vertical, 8)
                    }

                    // Error Message
                    if let error = viewModel.errorMessage {
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.red)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                    }

                    // Create Account Button
                    Button(action: {
                        Task {
                            await viewModel.signUp()
                        }
                    }) {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }
                            Text("Create Account")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(viewModel.canSubmit ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(!viewModel.canSubmit)

                    // Login Link
                    HStack {
                        Text("Already have an account?")
                            .foregroundColor(.secondary)

                        Button("Log In") {
                            dismiss()
                        }
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .onChange(of: viewModel.isRegistrationSuccessful) { success in
            if success {
                // Navigate to main app
                dismiss()
            }
        }
    }
}

struct RequirementRow: View {
    let text: String
    let met: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: met ? "checkmark.circle.fill" : "circle")
                .foregroundColor(met ? .green : .secondary)
                .font(.caption)

            Text(text)
                .font(.caption)
                .foregroundColor(met ? .primary : .secondary)
        }
    }
}

#Preview {
    SignUpView()
}
