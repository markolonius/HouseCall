//
//  AIConversationService.swift
//  HouseCall
//
//  AI Conversation Service - Business Logic Layer
//  Orchestrates message persistence and cloud sync (Phase 6.3).
//
//  Sending always routes through a CloudSyncCoordinator:
//    1. Persist user message locally (syncState = "pending")
//    2. POST to Core API via coordinator — on success: synced + serverId
//    3. AI reply arrives async via WebSocket (recommendation.delivered)
//
//  With no coordinator (signed out / cloud not configured) sending fails with
//  AIConversationError.signInRequired and nothing leaves the device.
//

import Foundation
import Combine
import CoreData

/// Service for managing AI conversations with streaming support
@MainActor
class AIConversationService: ObservableObject {
    // MARK: - Published Properties

    /// Current conversation being displayed
    @Published private(set) var currentConversation: Conversation?

    /// Messages in the current conversation
    @Published private(set) var messages: [Message] = []

    /// Current error message, if any
    @Published private(set) var errorMessage: String?

    /// Whether the cloud connection is usable. `.signInRequired` means there is
    /// no coordinator yet, or the Core API rejected the token (401): the chat is
    /// read-only until `activateCloud(_:)` is called after a fresh sign-in.
    @Published private(set) var cloudState: CloudSessionState = .signInRequired

    // MARK: - Dependencies

    private let conversationRepository: ConversationRepositoryProtocol
    private let messageRepository: MessageRepositoryProtocol
    private let auditLogger: AuditLogger

    /// Current user ID (authenticated user)
    private let userId: UUID

    /// Cloud sync coordinator injected when the Core API is available.
    /// `nil` means the patient is not signed in; sending fails with `signInRequired`.
    /// Attached after sign-in via `activateCloud(_:)`.
    private(set) var syncCoordinator: CloudSyncCoordinator?
    private var reauthSubscription: AnyCancellable?

    // MARK: - Initialization

    init(
        userId: UUID,
        conversationRepository: ConversationRepositoryProtocol,
        messageRepository: MessageRepositoryProtocol,
        auditLogger: AuditLogger = .shared,
        syncCoordinator: CloudSyncCoordinator? = nil
    ) {
        self.userId = userId
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.auditLogger = auditLogger
        if let syncCoordinator {
            activateCloud(syncCoordinator)
        }
    }

    // MARK: - Cloud session

    /// Attaches a (started) coordinator and marks the cloud session active.
    /// Replaces any previous coordinator, which is stopped. No restart needed.
    func activateCloud(_ coordinator: CloudSyncCoordinator) {
        if let old = syncCoordinator, old !== coordinator { old.stop() }
        syncCoordinator = coordinator
        errorMessage = nil
        cloudState = coordinator.requiresReauth ? .signInRequired : .active
        reauthSubscription = coordinator.$requiresReauth
            .dropFirst()
            .sink { [weak self] requiresReauth in
                guard let self, self.syncCoordinator === coordinator else { return }
                self.cloudState = requiresReauth ? .signInRequired : .active
            }
    }

    // MARK: - Conversation Management

    /// Creates a new conversation.
    /// - Parameter provider: Optional legacy provider tag. Normally nil: the app does not
    ///   choose a provider, so `llmProvider` keeps its Core Data schema default.
    /// - Returns: Created Conversation entity
    /// - Throws: ConversationRepositoryError or other errors
    func createConversation(provider: LLMProviderType? = nil) async throws -> Conversation {
        // Create conversation in repository
        let conversation = try conversationRepository.createConversation(
            userId: userId,
            provider: provider,
            title: nil
        )

        // Log conversation creation
        var info = ["conversationId": conversation.id!.uuidString]
        if let provider = provider {
            info["provider"] = provider.rawValue
        }
        try? auditLogger.log(
            event: .conversationCreated,
            userId: userId,
            details: AuditEventDetails(additionalInfo: info)
        )

        // Set as current conversation
        self.currentConversation = conversation
        self.messages = []

        return conversation
    }

    /// Loads an existing conversation
    /// - Parameter conversationId: UUID of the conversation to load
    /// - Throws: ConversationRepositoryError, MessageRepositoryError
    func loadConversation(_ conversationId: UUID) async throws {
        // Fetch conversation
        guard let conversation = try conversationRepository.fetchConversation(id: conversationId) else {
            throw ConversationRepositoryError.conversationNotFound
        }

        // Verify user owns this conversation
        guard conversation.userId == userId else {
            try? auditLogger.log(
                event: .unauthorizedAccess,
                userId: userId,
                details: AuditEventDetails(
                    message: "Attempted to access conversation owned by different user",
                    additionalInfo: ["conversationId": conversationId.uuidString]
                )
            )
            throw ConversationRepositoryError.conversationNotFound
        }

        // Fetch all messages
        let fetchedMessages = try messageRepository.fetchAllMessages(conversationId: conversationId)

        // Log conversation access
        try? auditLogger.log(
            event: .conversationAccessed,
            userId: userId,
            details: AuditEventDetails(
                additionalInfo: [
                    "conversationId": conversationId.uuidString,
                    "messageCount": "\(fetchedMessages.count)"
                ]
            )
        )

        // Update state
        self.currentConversation = conversation
        self.messages = fetchedMessages
    }

    // MARK: - Message Handling

    /// Sends a message by POSTing it to the Core API via the sync coordinator.
    ///
    ///  1. Persist user message with syncState = "pending"
    ///  2. POST via coordinator → on success: synced + serverId
    ///  3. AI reply arrives async via WebSocket (recommendation.delivered)
    ///
    /// With no coordinator the call throws `AIConversationError.signInRequired`
    /// before anything is persisted or sent.
    ///
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - content: User's message content
    /// - Throws: `AIConversationError.signInRequired` or repository / sync errors
    func sendMessage(conversationId: UUID, content: String) async throws {
        // Clear any previous errors
        errorMessage = nil

        // Validate content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageRepositoryError.invalidContent
        }

        // Ensure conversation exists and the user owns it
        guard let conversation = try conversationRepository.fetchConversation(id: conversationId) else {
            throw ConversationRepositoryError.conversationNotFound
        }
        guard conversation.userId == userId else {
            throw ConversationRepositoryError.conversationNotFound
        }

        // No coordinator means the patient is not signed in: nothing may leave the device.
        guard let coordinator = syncCoordinator, !coordinator.requiresReauth else {
            cloudState = .signInRequired
            errorMessage = AIConversationError.signInRequired.localizedDescription
            throw AIConversationError.signInRequired
        }

        // Persist user message with syncState = "pending" so it survives offline.
        let userMessage = try messageRepository.createMessage(
            conversationId: conversationId,
            role: .user,
            content: content,
            streamingComplete: true
        )
        // Set metadata on the saved message.
        setSyncState(on: userMessage, state: "pending")

        // Log message creation (no content logged — HIPAA)
        try? auditLogger.log(
            event: .messageCreated,
            userId: userId,
            details: AuditEventDetails(
                additionalInfo: [
                    "conversationId": conversationId.uuidString,
                    "role": MessageRole.user.rawValue
                ]
            )
        )

        // Update conversation title on first message
        if messages.isEmpty {
            let title = String(content.prefix(50))
            try conversationRepository.updateConversationTitle(id: conversationId, title: title)
        }

        // Update conversation timestamp
        try conversationRepository.updateConversationTimestamp(id: conversationId, timestamp: Date())

        // Add user message to the UI
        messages.append(userMessage)

        // A server-side conversation (serverId) is required before any
        // message can be POSTed. Launch-time ensureServerConversation is
        // best-effort; if it hasn't run or failed, create it on demand here
        // so the very first send is never silently dropped.
        var conversationServerId = conversation.serverId ?? ""
        if conversationServerId.isEmpty {
            await coordinator.ensureServerConversation(
                localConversationId: conversationId,
                title: "Consultation"
            )
            // Re-fetch to pick up the serverId ensureServerConversation persisted.
            if let refreshed = try? conversationRepository.fetchConversation(id: conversationId) {
                conversationServerId = refreshed.serverId ?? ""
            }
        }
        if !conversationServerId.isEmpty {
            try await coordinator.postMessage(
                localMessageId: userMessage.id!,
                conversationServerId: conversationServerId,
                conversationLocalId: conversationId
            )
        } else {
            // Could not establish a server conversation (offline / server
            // unreachable). Surface an error instead of silently dropping —
            // the message stays pending and replays on reconnect.
            errorMessage = "Unable to reach the server. Your message will be sent when the connection is restored."
        }
        // AI reply arrives asynchronously via WebSocket; no streaming UI here.
    }

    /// Clears the current conversation and messages, resetting all in-memory state.
    func clearCurrentConversation() {
        currentConversation = nil
        messages = []
        errorMessage = nil
    }

    // MARK: - Sync state helpers

    /// Sets syncState on a Core Data Message object without touching PHI fields.
    /// Best-effort; any error is silently discarded.
    private func setSyncState(on message: Message, state: String) {
        message.syncState = state
        let context = message.managedObjectContext
        try? context?.save()
    }
}

// MARK: - Cloud session state

/// Whether messages can currently be sent to the Core API.
enum CloudSessionState: Equatable {
    case active
    case signInRequired
}

// MARK: - Errors

/// Errors raised by `AIConversationService` (messages are PHI-free).
enum AIConversationError: LocalizedError, Equatable {
    case signInRequired

    var errorDescription: String? {
        switch self {
        case .signInRequired:
            return "Please sign in to send messages."
        }
    }
}
