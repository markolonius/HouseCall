//
//  ConversationViewModel.swift
//  HouseCall
//
//  ViewModel for Chat Interface - Bridges UI and AIConversationService
//  Manages conversation state and user interactions
//

import Foundation
import Combine
import CoreData

/// ViewModel for managing a single conversation's UI state
@MainActor
class ConversationViewModel: ObservableObject {
    // MARK: - Published Properties

    /// Current conversation being displayed
    @Published private(set) var currentConversation: Conversation?

    /// Messages in the current conversation
    @Published private(set) var messages: [Message] = []

    /// Current error message to display in UI
    @Published private(set) var errorMessage: String?

    /// `.signInRequired` puts the chat in read-only mode (history visible,
    /// input disabled, sign-in offered). The local session stays active.
    @Published private(set) var cloudState: CloudSessionState = .signInRequired

    /// True while a sign-in attempt is in flight.
    @Published private(set) var isSigningIn: Bool = false

    /// Sign-in failure message shown in the sign-in sheet (never contains PHI).
    @Published private(set) var signInError: String?

    /// Re-authenticates against the Core API and returns a started coordinator.
    /// Injected by the app; `nil` disables the sign-in action.
    typealias CloudSignIn = (_ password: String) async throws -> CloudSyncCoordinator
    private let cloudSignIn: CloudSignIn?

    /// Email of the current session, prefilled in the sign-in sheet.
    let signInEmail: String

    var isReadOnly: Bool { cloudState == .signInRequired }

    /// True while waiting for the agent's reply: the cloud session is active and
    /// the newest message is the patient's own (sent or pending send) with no
    /// assistant message after it. Computed from the message list so it
    /// survives relaunch and clears when any assistant message arrives.
    var isAwaitingReply: Bool {
        guard cloudState == .active, let last = messages.last else { return false }
        return last.role == MessageRole.user.rawValue && last.syncState != "failed"
    }

    // MARK: - Dependencies

    let conversationRepository: ConversationRepositoryProtocol
    let messageRepository: MessageRepositoryProtocol
    private let aiService: AIConversationService

    private let userId: UUID
    private let conversationId: UUID
    private var cancellables = Set<AnyCancellable>()
    private var coordinatorCancellables = Set<AnyCancellable>()

    // Last sent message for retry functionality
    private var lastMessageContent: String?

    /// Recommendation cards delivered via WebSocket for this conversation.
    @Published private(set) var recommendationCards: [RecommendationCardModel] = []

    // MARK: - Initialization

    init(
        userId: UUID,
        conversationId: UUID,
        conversationRepository: ConversationRepositoryProtocol,
        messageRepository: MessageRepositoryProtocol,
        aiService: AIConversationService? = nil,
        signInEmail: String = "",
        cloudSignIn: CloudSignIn? = nil
    ) {
        self.signInEmail = signInEmail
        self.cloudSignIn = cloudSignIn
        self.userId = userId
        self.conversationId = conversationId
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository

        // Create or use provided AI service
        if let service = aiService {
            self.aiService = service
        } else {
            self.aiService = AIConversationService(
                userId: userId,
                conversationRepository: conversationRepository,
                messageRepository: messageRepository
            )
        }

        // Observe AI service changes
        setupServiceObservers()
    }

    // MARK: - Public Methods

    /// Load the conversation and its messages
    func loadConversation() {
        Task {
            do {
                try await aiService.loadConversation(conversationId)
            } catch {
                handleError(error)
            }
        }
    }

    /// Load messages for the current conversation
    ///
    /// Routes through `aiService.loadConversation` (not a direct repository
    /// fetch) so `aiService.messages` stays the single source of truth. The
    /// aiService's own `$messages` publisher is what mirrors into
    /// `self.messages` (see `setupServiceObservers`) — fetching directly here
    /// created a second, uncoordinated writer that could race with that
    /// mirror. When `aiService.messages` was still a session-local, partial
    /// array (e.g. only the just-appended user message on the cloud send
    /// path), its publish would stomp the fuller array this method had just
    /// set directly, flashing the chat list down to a handful of messages
    /// until the next WebSocket-triggered refresh corrected it.
    func loadMessages() {
        loadConversation()
    }

    /// Send a message to the AI
    /// - Parameter content: The message text to send
    func sendMessage(content: String) async {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        lastMessageContent = content

        do {
            try await aiService.sendMessage(conversationId: conversationId, content: content)
        } catch {
            handleError(error)
        }
    }

    /// Retry the last sent message
    func retryLastMessage() {
        guard let lastContent = lastMessageContent else { return }

        clearError()

        Task {
            await sendMessage(content: lastContent)
        }
    }

    /// Clear the current error message
    func clearError() {
        errorMessage = nil
    }

    // MARK: - Private Methods

    private func setupServiceObservers() {
        // Observe conversation changes
        aiService.$currentConversation
            .receive(on: DispatchQueue.main)
            .sink { [weak self] conversation in
                self?.currentConversation = conversation
            }
            .store(in: &cancellables)

        // Observe message changes
        aiService.$messages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messages in
                self?.messages = messages
            }
            .store(in: &cancellables)

        aiService.$cloudState
            .sink { [weak self] state in
                self?.cloudState = state
            }
            .store(in: &cancellables)

        // Observe errors
        aiService.$errorMessage
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                if let error = error {
                    self?.errorMessage = error
                }
            }
            .store(in: &cancellables)

        if let coordinator = aiService.syncCoordinator {
            observeCoordinator(coordinator)
        }
    }

    /// Subscribes to a coordinator's delivered cards / synced-message counter.
    private func observeCoordinator(_ coordinator: CloudSyncCoordinator) {
        coordinatorCancellables.removeAll()
        // Observe delivered recommendation cards from the sync coordinator.
        // Filter to cards belonging to this conversation only.
        coordinator.$deliveredCards
            .receive(on: DispatchQueue.main)
            .sink { [weak self] allCards in
                guard let self else { return }
                self.recommendationCards = allCards.filter {
                    $0.conversationLocalId == self.conversationId
                }
                // Reload messages so the newly-persisted assistant message
                // from the recommendation handler appears in the list.
                if !self.recommendationCards.isEmpty {
                    self.loadMessages()
                }
            }
            .store(in: &coordinatorCancellables)

        // Observe syncedMessageCount so agent interview questions that
        // arrive via `message.created` (no card model) also trigger a
        // message list refresh.
        coordinator.$syncedMessageCount
            .receive(on: DispatchQueue.main)
            .dropFirst()  // skip initial 0 value on subscription
            .sink { [weak self] _ in
                self?.loadMessages()
            }
            .store(in: &coordinatorCancellables)
    }

    /// Signs in again with the Core API and activates cloud sync in place.
    /// Returns true on success. The local session is never touched on failure.
    @discardableResult
    func signIn(password: String) async -> Bool {
        guard let cloudSignIn, !isSigningIn else { return false }
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let coordinator = try await cloudSignIn(password)
            aiService.activateCloud(coordinator)
            observeCoordinator(coordinator)
            errorMessage = nil
            loadMessages()
            return true
        } catch {
            signInError = "Unable to sign in. Check your password and connection."
            return false
        }
    }

    private func handleError(_ error: Error) {
        // Convert technical errors to user-friendly messages
        if let aiError = error as? AIConversationError {
            // Signed-out send: show the sign-in prompt only. This is expected
            // behaviour, not an AI failure, so it is not audit-logged as one,
            // and the banner offers no Retry (it only does for connect/timeout).
            errorMessage = aiError.localizedDescription
            if aiError == .signInRequired { return }
        } else if let _ = error as? ConversationRepositoryError {
            errorMessage = "Unable to load conversation. Please try again."
        } else if let _ = error as? MessageRepositoryError {
            errorMessage = "Unable to save message. Please try again."
        } else {
            errorMessage = "An unexpected error occurred. Please try again."
        }

        // Log error without PHI — no error description or message content
        try? AuditLogger.shared.log(
            event: .aiInteractionFailed,
            userId: nil,
            details: AuditEventDetails(errorMessage: "conversation view error")
        )
    }
}
