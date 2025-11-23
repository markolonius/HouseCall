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

// MARK: - Main App View (AI Chat Interface)

struct MainAppView: View {
    @EnvironmentObject var authService: AuthenticationService
    @Environment(\.managedObjectContext) private var viewContext

    var body: some View {
        TabView {
            // Conversations Tab
            conversationsTab
                .tabItem {
                    Label("Chat", systemImage: "bubble.left.and.bubble.right")
                }

            // Profile Tab
            profileTab
                .tabItem {
                    Label("Profile", systemImage: "person.circle")
                }
        }
    }

    // MARK: - Tabs

    private var conversationsTab: some View {
        Group {
            if let user = authService.getCurrentUser(), let userId = user.id {
                ConversationListView(
                    userId: userId,
                    conversationRepository: CoreDataConversationRepository(context: viewContext),
                    messageRepository: CoreDataMessageRepository(context: viewContext)
                )
            } else {
                Text("Unable to load conversations")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var profileTab: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // User Info Section
                if let user = authService.getCurrentUser() {
                    VStack(spacing: 16) {
                        Image(systemName: "person.circle.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.blue)

                        VStack(spacing: 8) {
                            if let fullName = try? authService.getCurrentUserFullName() {
                                Text(fullName)
                                    .font(.title2)
                                    .fontWeight(.semibold)
                            }

                            Text(user.email ?? "")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(Color(.systemBackground))
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                }

                Spacer()

                // App Info
                VStack(spacing: 8) {
                    Text("🏥 HouseCall")
                        .font(.title3)
                        .fontWeight(.bold)

                    Text("AI Healthcare Assistant")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("HIPAA-Compliant • Encrypted • Secure")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.top, 4)
                }
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
            .navigationTitle("Profile")
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AuthenticationService.shared)
}
