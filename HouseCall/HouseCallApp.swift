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

    // Declared without a default value so that init() can run the UI-test
    // bootstrap (session-clear + test-user seed) BEFORE AuthenticationService
    // is initialised and calls restoreSession().
    @StateObject private var authService: AuthenticationService
    @StateObject private var screenProtectionManager: ScreenProtectionManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        #if DEBUG
        // Must run before AuthenticationService.shared is initialised.
        // Clears any leftover Keychain session and seeds the synthetic test
        // account so UI tests always start on the login screen.
        UITestBootstrap.prepareIfNeeded()
        #endif
        _authService = StateObject(wrappedValue: AuthenticationService.shared)
        _screenProtectionManager = StateObject(wrappedValue: ScreenProtectionManager.shared)
    }

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
                    provider: LLMProviderConfigManager.shared.getActiveProvider(),
                    title: nil
                )
            }
            guard let conversationId = conversation.id else {
                launchState = .failed("Unable to open your conversation. Please try again.")
                return
            }

            // Build a cloud-sync coordinator only when the Core API base URL
            // is configured AND a JWT is already present in the Keychain.
            // Otherwise pass nil so the service uses the direct-LLM path.
            let coordinator = buildCloudSyncCoordinator(
                conversationRepository: conversationRepository,
                messageRepository: messageRepository
            )
            let aiService = AIConversationService(
                userId: userId,
                conversationRepository: conversationRepository,
                messageRepository: messageRepository,
                syncCoordinator: coordinator
            )
            coordinator?.start()

            chatViewModel = ConversationViewModel(
                userId: userId,
                conversationId: conversationId,
                conversationRepository: conversationRepository,
                messageRepository: messageRepository,
                aiService: aiService
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

// MARK: - Build-time config helpers
//
// Delegated to CoreAPIConfig (Core/Services/Sync/CoreAPIConfig.swift) which is
// the single source of truth used by both HouseCallApp and AuthenticationService.

// MARK: - Cloud sync coordinator factory

/// Constructs a `SyncClient` + `CloudSyncCoordinator` for the production app
/// ONLY when both conditions are met:
///   1. `CoreAPIBaseURL` in Info.plist (fed by the `CORE_API_BASE_URL` xcconfig
///      setting) resolves to a non-empty, valid URL.
///   2. A Core API JWT is present in the Keychain under `Keys.coreAPIJWT`.
///
/// Returns `nil` in all other cases so the caller falls back to the
/// direct-LLM path with no behaviour change.
///
/// NOTE: A successful cloud login/registration (when `CoreAPIBaseURL` +
/// `CoreAPITenantID` are configured) stores the JWT under `Keys.coreAPIJWT`, so
/// this gate activates for an authenticated patient. With no Core API config the
/// JWT is never written and this returns `nil` (local-only default build).
@MainActor
private func buildCloudSyncCoordinator(
    conversationRepository: ConversationRepositoryProtocol,
    messageRepository: MessageRepositoryProtocol
) -> CloudSyncCoordinator? {
    // Gate 1: Core API base URL must be configured at build time.
    guard
        let urlString = CoreAPIConfig.baseURLString(),
        let baseURL = URL(string: urlString)
    else { return nil }

    // Gate 2: A JWT must already be present in the Keychain.
    // `try?` on a throws-returning-Optional flattens to Optional<String> (SE-0230).
    guard
        let jwt = try? KeychainManager.shared.get(key: KeychainManager.Keys.coreAPIJWT),
        !jwt.isEmpty
    else { return nil }

    // Both gates passed — build the coordinator.
    guard let syncClient = try? SyncClient(baseURL: baseURL) else { return nil }
    return CloudSyncCoordinator(
        syncClient: syncClient,
        messageRepository: messageRepository,
        conversationRepository: conversationRepository
    )
}

#if DEBUG
// MARK: - UI Test Bootstrap (DEBUG only — never shipped in production builds)

/// Bootstraps a deterministic synthetic test account when the app is launched
/// under XCUITest.  Protected by BOTH a compiler flag (#if DEBUG) and the
/// explicit "UI-TESTING" launch argument, so it cannot activate in a Release
/// build or in a normal debug run that omits the argument.
///
/// HIPAA note: the seeded account uses a wholly synthetic identifier
/// (uitest@housecall.app) with no real patient data. The bootstrap is
/// idempotent — if the test user already exists the creation error is
/// swallowed. No PHI is logged.
enum UITestBootstrap {
    // Must stay in sync with ChatInterfaceUITests.loginTestUser().
    static let testEmail    = "uitest@housecall.app"
    static let testPassword = "UITest12345!"

    static func prepareIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("UI-TESTING") else { return }

        // 1. Clear any Keychain session token left over from a previous test
        //    run so AuthenticationService.restoreSession() finds nothing and
        //    the app always starts on the login screen.
        try? KeychainManager.shared.deleteSessionToken()

        // 2. Seed the synthetic test account (no-op if it already exists).
        let repo = CoreDataUserRepository()
        guard !repo.isEmailRegistered(testEmail) else { return }
        _ = try? repo.createUser(
            email: testEmail,
            password: testPassword,
            passcode: nil,
            fullName: "UI Test",      // Synthetic — not real PHI
            authMethod: .password
        )
    }
}
#endif

#Preview {
    RootView()
        .environmentObject(AuthenticationService.shared)
}
