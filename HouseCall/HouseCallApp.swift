//
//  HouseCallApp.swift
//  HouseCall
//
//  Created by Marko Dimiskovski on 11/17/25.
//

import SwiftUI
import CoreData

@main
struct HouseCallApp: App {
    let persistenceController = PersistenceController.shared

    @StateObject private var authService = AuthenticationService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(authService)
        }
    }
}

// MARK: - Root Navigation View

struct RootView: View {
    @EnvironmentObject var authService: AuthenticationService

    var body: some View {
        Group {
            if authService.isAuthenticated {
                // User is authenticated - show main app
                MainAppView()
            } else {
                // No authentication - show login
                LoginView()
            }
        }
        .onAppear {
            // Validate session on app launch
            _ = authService.validateSession()
        }
    }
}

// MARK: - Main App View (Placeholder for AI Chat)

struct MainAppView: View {
    @EnvironmentObject var authService: AuthenticationService

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                Text("🏥 HouseCall")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("AI Healthcare Assistant")
                    .font(.title2)
                    .foregroundColor(.secondary)

                if let user = authService.getCurrentUser() {
                    VStack(spacing: 8) {
                        Text("Welcome!")
                            .font(.headline)

                        Text(user.email ?? "")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        if let fullName = try? authService.getCurrentUserFullName() {
                            Text(fullName)
                                .font(.title3)
                                .fontWeight(.medium)
                        }
                    }
                    .padding()
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(12)
                }

                Spacer()

                Text("AI Chat Interface Coming Soon")
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .padding()

                Spacer()

                // Logout Button
                Button(action: {
                    Task {
                        try? await authService.logout()
                    }
                }) {
                    Text("Logout")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.red.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("HouseCall")
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AuthenticationService.shared)
}
