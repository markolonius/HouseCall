//
//  ProfileView.swift
//  HouseCall
//
//  User profile sheet — shows account info, AI provider settings link,
//  app about section, and a logout button.
//  Presented as a sheet from the chat toolbar's Profile button.
//

import SwiftUI

struct ProfileView: View {
    @EnvironmentObject var authService: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // MARK: - User Info Section
                Section {
                    if let user = authService.getCurrentUser() {
                        HStack(spacing: 16) {
                            Image(systemName: "person.circle.fill")
                                .font(.system(size: 60))
                                .foregroundColor(.blue)

                            VStack(alignment: .leading, spacing: 4) {
                                if let fullName = try? authService.getCurrentUserFullName() {
                                    Text(fullName)
                                        .font(.title3)
                                        .fontWeight(.semibold)
                                }

                                Text(user.email ?? "")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }

                // MARK: - Settings Section
                Section(header: Text("Settings")) {
                    NavigationLink(destination: LLMProviderSettingsView()) {
                        Label("AI Provider Settings", systemImage: "cpu")
                    }
                }

                // MARK: - About Section
                Section(header: Text("About")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("🏥 HouseCall")
                            .font(.headline)
                            .fontWeight(.bold)

                        Text("AI Healthcare Assistant")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Text("HIPAA-Compliant • Encrypted • Secure")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                }

                // MARK: - Logout Section
                Section {
                    Button(action: {
                        Task {
                            try? await authService.logout()
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text("Logout")
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ProfileView()
        .environmentObject(AuthenticationService.shared)
}
