//
//  LoginView.swift
//  HouseCall
//
//  User login view with biometric support
//

import SwiftUI

struct LoginView: View {
    @State private var viewModel = LoginViewModel()
    @State private var showingSignUp = false
    @EnvironmentObject var authService: AuthenticationService

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 12) {
                        Text("Welcome Back")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Sign in to access your health information")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 64)

                    // Form Fields
                    VStack(spacing: 20) {
                        // Email
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Email Address")
                                .font(.headline)

                            TextField("email@example.com", text: $viewModel.email)
                                .textContentType(.emailAddress)
                                .autocapitalization(.none)
                                .keyboardType(.emailAddress)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                        }

                        // Credential (Password or Passcode)
                        if !viewModel.useBiometric {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(viewModel.credentialPlaceholder)
                                    .font(.headline)

                                if viewModel.authMethod == .passcode {
                                    TextField("Enter 6-digit passcode", text: $viewModel.credential)
                                        .textContentType(.password)
                                        .keyboardType(.numberPad)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                } else {
                                    SecureField("Enter password", text: $viewModel.credential)
                                        .textContentType(.password)
                                        .textFieldStyle(RoundedBorderTextFieldStyle())
                                }
                            }
                        }

                        // Biometric Toggle
                        if viewModel.biometricType != .none {
                            Toggle(isOn: $viewModel.useBiometric) {
                                HStack {
                                    Image(systemName: viewModel.biometricIconName)
                                        .font(.title3)

                                    Text("Use \(viewModel.biometricType.displayName)")
                                        .font(.headline)
                                }
                            }
                            .tint(.blue)
                        }
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

                    // Login Button
                    Button(action: {
                        Task {
                            await viewModel.login()
                        }
                    }) {
                        HStack {
                            if viewModel.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            }

                            if viewModel.useBiometric {
                                Image(systemName: viewModel.biometricIconName)
                                Text("Log In with \(viewModel.biometricType.displayName)")
                                    .fontWeight(.semibold)
                            } else {
                                Text("Log In")
                                    .fontWeight(.semibold)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(viewModel.canSubmit ? Color.blue : Color.gray)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .disabled(!viewModel.canSubmit)

                    // Sign Up Link
                    VStack(spacing: 16) {
                        Divider()

                        HStack {
                            Text("Don't have an account?")
                                .foregroundColor(.secondary)

                            Button("Sign Up") {
                                showingSignUp = true
                            }
                        }
                        .font(.subheadline)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $showingSignUp) {
            SignUpView()
        }
        .onChange(of: authService.isAuthenticated) { isAuth in
            if isAuth {
                print("🟢 LoginView detected authentication, closing sheet")
                showingSignUp = false
            }
        }
    }
}

#Preview {
    LoginView()
}
