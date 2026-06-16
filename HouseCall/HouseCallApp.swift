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
        // Tab bar removed; chat is the single root authenticated view.
        // Profile is accessible via the toolbar button in ChatView (ProfileView sheet).
        chatRootView
    }

    // MARK: - Chat Root

    private var chatRootView: some View {
        Group {
            if let user = authService.getCurrentUser(), let userId = user.id {
                AutoLaunchChatView(
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

}

// MARK: - Auto-Launch Chat View

/// Resolves the patient's most-recent conversation (or creates one if none
/// exists) and presents `ChatView` directly — no list, no "New Chat" step.
private struct AutoLaunchChatView: View {

    let userId: UUID
    let conversationRepository: ConversationRepositoryProtocol
    let messageRepository: MessageRepositoryProtocol

    private enum LaunchState {
        case loading
        case ready
        case failed(String)
    }

    @State private var launchState: LaunchState = .loading
    /// Incremented on each retry to re-trigger the `.task(id:)` modifier.
    @State private var loadAttempt: Int = 0
    /// Retained across re-renders once resolved.
    @State private var chatViewModel: ConversationViewModel?

    var body: some View {
        NavigationStack {
            contentView
        }
        .task(id: loadAttempt) {
            await resolveConversation()
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch launchState {
        case .loading:
            ProgressView("Opening conversation…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .ready:
            if let vm = chatViewModel {
                ChatView(viewModel: vm)
            }

        case .failed(let message):
            VStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.secondary)

                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 32)

                Button("Try Again") {
                    launchState = .loading
                    loadAttempt += 1
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    // MARK: - Conversation Resolution

    /// Fetches the most-recently-updated conversation for this user, or creates
    /// a new one with the default provider if none exist.
    /// No PHI is written to logs — only identifiers and event names.
    private func resolveConversation() async {
        do {
            // fetchConversations returns results sorted by updatedAt descending,
            // so .first is the most-recently-updated conversation.
            let conversations = try conversationRepository.fetchConversations(userId: userId)
            let conversation: Conversation
            if let existing = conversations.first {
                conversation = existing
            } else {
                conversation = try conversationRepository.createConversation(
                    userId: userId,
                    provider: .openai,
                    title: nil
                )
            }
            guard let conversationId = conversation.id else {
                launchState = .failed("Unable to open your conversation. Please try again.")
                return
            }
            chatViewModel = ConversationViewModel(
                userId: userId,
                conversationId: conversationId,
                conversationRepository: conversationRepository,
                messageRepository: messageRepository
            )
            launchState = .ready
        } catch {
            // Log the event without PHI.
            try? AuditLogger.shared.log(
                event: .aiInteractionFailed,
                userId: userId,
                details: AuditEventDetails(errorMessage: "auto-launch conversation resolve failed")
            )
            launchState = .failed("Unable to open your conversation. Please try again.")
        }
    }
}

#Preview {
    RootView()
        .environmentObject(AuthenticationService.shared)
}
