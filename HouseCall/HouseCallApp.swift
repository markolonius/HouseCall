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
    @StateObject private var screenProtectionManager = ScreenProtectionManager.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
                .environmentObject(authService)
                .environmentObject(screenProtectionManager)
                .overlay {
                    // Privacy screen overlay when app is backgrounded
                    if screenProtectionManager.showPrivacyScreen {
                        PrivacyScreenView()
                    }
                }
        }
        .onChange(of: scenePhase) { oldPhase, newPhase in
            handleScenePhaseChange(from: oldPhase, to: newPhase)
        }
    }

    // MARK: - Scene Phase Handling

    /// Handles scene phase transitions for privacy protection
    private func handleScenePhaseChange(from oldPhase: ScenePhase, to newPhase: ScenePhase) {
        switch newPhase {
        case .active:
            // App became active - hide privacy screen
            screenProtectionManager.showPrivacyScreen = false

        case .inactive:
            // App is transitioning (e.g., during app switcher)
            // Show privacy screen immediately to hide sensitive content
            screenProtectionManager.showPrivacyScreen = true

        case .background:
            // App moved to background - ensure privacy screen is shown
            screenProtectionManager.showPrivacyScreen = true

        @unknown default:
            break
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
            List {
                // User Info Section
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

                // Settings Section
                Section(header: Text("Settings")) {
                    NavigationLink(destination: LLMProviderSettingsView()) {
                        Label("AI Provider Settings", systemImage: "cpu")
                    }
                }

                // App Info Section
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

                // Logout Section
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
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AuthenticationService.shared)
}
