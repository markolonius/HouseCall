//
//  AIConversationService.swift
//  HouseCall
//
//  AI Conversation Service - Business Logic Layer
//  Orchestrates message persistence and cloud sync (Phase 6.3).
//
//  When a CloudSyncCoordinator is injected the send path becomes:
//    1. Persist user message locally (syncState = "pending")
//    2. POST to Core API via coordinator — on success: synced + serverId
//    3. AI reply arrives async via WebSocket (recommendation.delivered)
//
//  When no coordinator is supplied the legacy LLM-provider streaming path
//  is used (offline/dev mode).
//

import Foundation
import Combine
import CoreData

/// Tracks which phase of the clinical interview is active for the current conversation.
///
/// Phase is held in-memory only (no Core Data persistence). A conversation
/// reopened later always starts back in `.gathering`.
///
/// - `gathering`: normal history-taking turns — uses the interview prompt and
///   the small per-turn token budget.
/// - `summary`: the closing turn — uses the summary prompt and the larger
///   token budget. Phase 3.2 flips to this state and returns to `.gathering`
///   after the summary turn completes.
enum InterviewPhase {
    case gathering
    case summary
}

/// Service for managing AI conversations with streaming support
@MainActor
class AIConversationService: ObservableObject {
    // MARK: - Published Properties

    /// Current conversation being displayed
    @Published private(set) var currentConversation: Conversation?

    /// Messages in the current conversation
    @Published private(set) var messages: [Message] = []

    /// Whether an AI response is currently streaming
    @Published private(set) var isStreaming: Bool = false

    /// Current error message, if any
    @Published private(set) var errorMessage: String?

    /// Current streaming response text (accumulates as chunks arrive)
    @Published private(set) var streamingText: String = ""

    /// ID of the message currently being streamed
    @Published private(set) var streamingMessageId: UUID?

    /// Current interview phase for this conversation (in-memory only; resets to
    /// `.gathering` when the conversation is closed or the app restarts).
    /// Observe this from the view model to enable/disable phase-specific controls.
    @Published private(set) var interviewPhase: InterviewPhase = .gathering

    // MARK: - Interview Turn Budgets

    /// Per-phase token budgets for clinical interview turns.
    ///
    /// A small budget physically caps turn length, preventing essay-length replies
    /// even when the model ignores the brevity instruction in the system prompt.
    ///
    /// - `gatheringMaxTokens` (~160): one short question per gathering turn.
    /// - `summaryMaxTokens` (~512): room for the structured closing summary.
    ///
    /// Phase 3 selects between them via the `summaryTurn` parameter on `sendMessage`.
    /// Internal (not private) so that unit tests can assert their exact values
    /// without hard-coding magic numbers.
    static let gatheringMaxTokens = 160
    static let summaryMaxTokens   = 512

    // MARK: - Dependencies

    private let conversationRepository: ConversationRepositoryProtocol
    private let messageRepository: MessageRepositoryProtocol
    private let providerConfigManager: LLMProviderConfigManager
    private let auditLogger: AuditLogger

    /// Current user ID (authenticated user)
    private let userId: UUID

    /// Active LLM provider for streaming requests (legacy / offline path only)
    private var currentProvider: LLMProvider?

    #if DEBUG
    /// Optional provider override injected by tests.
    ///
    /// When non-nil this provider is used unconditionally for every `sendMessage`
    /// call in the legacy streaming path, bypassing the config-manager lookup and
    /// the `isProviderConfigured` gate.  Set this ONLY in test code; production
    /// call sites always leave it nil.  Compiled out of Release builds.
    var _testProviderOverride: LLMProvider?
    #endif

    /// Cloud sync coordinator injected when the Core API is available.
    /// `nil` means fall back to the legacy LLM-provider streaming path.
    let syncCoordinator: CloudSyncCoordinator?

    // MARK: - Initialization

    init(
        userId: UUID,
        conversationRepository: ConversationRepositoryProtocol,
        messageRepository: MessageRepositoryProtocol,
        providerConfigManager: LLMProviderConfigManager = .shared,
        auditLogger: AuditLogger = .shared,
        syncCoordinator: CloudSyncCoordinator? = nil
    ) {
        self.userId = userId
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.providerConfigManager = providerConfigManager
        self.auditLogger = auditLogger
        self.syncCoordinator = syncCoordinator
    }

    // MARK: - Conversation Management

    /// Creates a new conversation with the specified provider
    /// - Parameter provider: LLM provider type to use (defaults to active provider)
    /// - Returns: Created Conversation entity
    /// - Throws: ConversationRepositoryError or other errors
    func createConversation(provider: LLMProviderType? = nil) async throws -> Conversation {
        let selectedProvider = provider ?? providerConfigManager.getActiveProvider()

        // Verify provider is configured.
        // In DEBUG builds a test-provider override bypasses this check so that
        // tests can exercise conversation / message logic without live API keys.
        #if DEBUG
        guard _testProviderOverride != nil || providerConfigManager.isProviderConfigured(selectedProvider) else {
            throw LLMError.notConfigured
        }
        #else
        guard providerConfigManager.isProviderConfigured(selectedProvider) else {
            throw LLMError.notConfigured
        }
        #endif

        // Create conversation in repository
        let conversation = try conversationRepository.createConversation(
            userId: userId,
            provider: selectedProvider,
            title: nil
        )

        // Log conversation creation
        try? auditLogger.log(
            event: .conversationCreated,
            userId: userId,
            details: AuditEventDetails(
                additionalInfo: [
                    "conversationId": conversation.id!.uuidString,
                    "provider": selectedProvider.rawValue
                ]
            )
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

    /// Sends a message and either POSTs to the Core API (cloud path) or falls
    /// back to legacy LLM streaming (offline / dev mode).
    ///
    /// Cloud path (syncCoordinator != nil):
    ///  1. Persist user message with syncState = "pending"
    ///  2. POST via coordinator → on success: synced + serverId
    ///  3. AI reply arrives async via WebSocket (recommendation.delivered)
    ///
    /// Legacy path (syncCoordinator == nil):
    ///  - Streams a response inline from the configured LLM provider.
    ///
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - content: User's message content
    /// - Throws: Various errors from repositories and LLM providers
    func sendMessage(conversationId: UUID, content: String, summaryTurn: Bool = false) async throws {
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

        // --- Cloud sync path ---
        if let coordinator = syncCoordinator {
            // serverId for the conversation is required to POST; if absent the
            // message stays pending and replay will retry when available.
            let conversationServerId = conversation.serverId ?? ""
            if !conversationServerId.isEmpty {
                try await coordinator.postMessage(
                    localMessageId: userMessage.id!,
                    conversationServerId: conversationServerId,
                    conversationLocalId: conversationId
                )
            }
            // AI reply arrives asynchronously via WebSocket; no streaming UI here.
            return
        }

        // --- Legacy LLM streaming path (no coordinator injected) ---
        let (provider, providerType) = try resolveProvider(for: conversation)
        self.currentProvider = provider
        try await streamAssistantTurn(
            conversationId: conversationId,
            provider: provider,
            providerType: providerType,
            summaryTurn: summaryTurn
        )
    }

    /// Transitions the current interview to its summary turn.
    ///
    /// Sets `interviewPhase` to `.summary`, runs a single assistant turn using
    /// the summary prompt and the larger token budget, then resets the phase to
    /// `.gathering` so the patient can continue the conversation.  No user
    /// message is persisted — the model is asked to synthesise the history
    /// gathered so far.
    ///
    /// Phase reset is guaranteed:
    /// - On a synchronous setup error the `catch` block below resets immediately.
    /// - On an asynchronous stream outcome `handleStreamComplete` resets at the
    ///   end of the turn.
    ///
    /// - Parameter conversationId: UUID of the conversation to summarise.
    /// - Throws: `ConversationRepositoryError.conversationNotFound` if the
    ///   conversation does not exist or belongs to a different user;
    ///   `LLMError.notConfigured` if no LLM provider is available;
    ///   `MessageRepositoryError` on persistence failure.
    func requestSummary(conversationId: UUID) async throws {
        errorMessage = nil

        guard let conversation = try conversationRepository.fetchConversation(id: conversationId) else {
            throw ConversationRepositoryError.conversationNotFound
        }
        guard conversation.userId == userId else {
            throw ConversationRepositoryError.conversationNotFound
        }

        // The summary-turn transition is recorded by the single
        // `.aiStreamingStarted` audit event emitted in `streamAssistantTurn`
        // (it carries `summaryTransition` when this turn is a summary), so no
        // separate event is logged here — keeps one start-event per turn.

        // Flip to summary phase.  On a synchronous setup error the catch block
        // below resets immediately; on an asynchronous stream outcome
        // handleStreamComplete resets at the end of the turn.
        interviewPhase = .summary

        do {
            let (provider, providerType) = try resolveProvider(for: conversation)
            self.currentProvider = provider
            // Run one assistant turn with the summary prompt — no user message is created.
            try await streamAssistantTurn(
                conversationId: conversationId,
                provider: provider,
                providerType: providerType,
                summaryTurn: true
            )
        } catch {
            // Synchronous setup failed — reset phase immediately so the service
            // is not stuck in .summary.
            interviewPhase = .gathering
            throw error
        }
    }

    /// Cancels the current streaming request
    func cancelStreaming() {
        currentProvider?.cancelStreaming()
        isStreaming = false
        streamingMessageId = nil
        streamingText = ""

        // Log interruption
        if let conversationId = currentConversation?.id {
            try? auditLogger.log(
                event: .aiStreamingInterrupted,
                userId: userId,
                details: AuditEventDetails(
                    message: "User cancelled streaming",
                    additionalInfo: ["conversationId": conversationId.uuidString]
                )
            )
        }
    }

    // MARK: - Private Methods

    /// Resolves the LLM provider instance and type for a given conversation.
    ///
    /// Falls back to the active (build-config) provider when the stored provider
    /// is not configured.  This rescues conversations created under an older
    /// default provider (e.g. "openai") once the app is pointed at a hardcoded
    /// provider.  In DEBUG builds, returns the test-injected override when present.
    ///
    /// - Parameter conversation: The conversation for which to resolve the provider.
    /// - Returns: A tuple of the resolved `LLMProvider` instance and its type.
    /// - Throws: `LLMError.notConfigured` if no usable provider is available.
    private func resolveProvider(for conversation: Conversation) throws -> (LLMProvider, LLMProviderType) {
        var providerType = LLMProviderType(rawValue: conversation.llmProvider ?? "openai") ?? .openai
        if !providerConfigManager.isProviderConfigured(providerType) {
            providerType = providerConfigManager.getActiveProvider()
        }
        // In DEBUG builds use the test-injected provider when present;
        // otherwise (and always in Release) resolve via the config manager.
        #if DEBUG
        if let override = _testProviderOverride {
            return (override, providerType)
        }
        #endif
        guard let resolved = providerConfigManager.createProvider(type: providerType) else {
            throw LLMError.notConfigured
        }
        guard resolved.isConfigured else {
            throw LLMError.notConfigured
        }
        return (resolved, providerType)
    }

    /// Creates the AI placeholder message, builds the chat context, and starts
    /// the streaming turn.  Does NOT create or persist a user message.
    ///
    /// On success the streaming session is live; `handleStreamComplete` fires
    /// asynchronously when the provider closes the stream.
    /// On a synchronous setup failure the placeholder message is removed and the
    /// error is rethrown.
    ///
    /// - Parameters:
    ///   - conversationId: UUID of the conversation receiving the turn.
    ///   - provider:       Resolved `LLMProvider` instance.
    ///   - providerType:   Provider type used for audit logging.
    ///   - summaryTurn:    When `true`, selects the summary prompt and the larger
    ///                     token budget; `false` selects the gathering prompt.
    /// - Throws: `MessageRepositoryError`, `LLMError`, or any error thrown by
    ///   the provider's `streamCompletion` during request setup.
    private func streamAssistantTurn(
        conversationId: UUID,
        provider: LLMProvider,
        providerType: LLMProviderType,
        summaryTurn: Bool
    ) async throws {
        // Create placeholder AI message
        let aiMessage = try messageRepository.createMessage(
            conversationId: conversationId,
            role: .assistant,
            content: "",
            streamingComplete: false
        )

        messages.append(aiMessage)
        streamingMessageId = aiMessage.id
        streamingText = ""
        isStreaming = true

        // Choose the per-phase token budget and prompt variant.  Summary budget
        // and prompt always travel together so the model receives consistent
        // instructions for each phase.
        let maxTokens = summaryTurn
            ? AIConversationService.summaryMaxTokens
            : AIConversationService.gatheringMaxTokens
        let chatMessages = try buildChatContext(conversationId: conversationId, useSummaryPrompt: summaryTurn)

        var streamingStartedInfo = [
            "conversationId": conversationId.uuidString,
            "provider": providerType.rawValue
        ]
        if summaryTurn {
            streamingStartedInfo["summaryTransition"] = "true"
        }
        try? auditLogger.log(
            event: .aiStreamingStarted,
            userId: userId,
            details: AuditEventDetails(additionalInfo: streamingStartedInfo)
        )

        do {
            try await provider.streamCompletion(
                messages: chatMessages,
                maxTokensOverride: maxTokens,
                onChunk: { [weak self] chunk in
                    Task { @MainActor in
                        self?.handleStreamChunk(chunk, messageId: aiMessage.id!)
                    }
                },
                onComplete: { [weak self] result in
                    Task { @MainActor in
                        await self?.handleStreamComplete(
                            result: result,
                            messageId: aiMessage.id!,
                            conversationId: conversationId,
                            providerType: providerType
                        )
                    }
                }
            )
        } catch {
            isStreaming = false
            streamingMessageId = nil

            try? auditLogger.log(
                event: .aiInteractionFailed,
                userId: userId,
                details: AuditEventDetails(
                    errorMessage: error.localizedDescription,
                    additionalInfo: [
                        "conversationId": conversationId.uuidString,
                        "provider": providerType.rawValue
                    ]
                )
            )

            if let index = messages.firstIndex(where: { $0.id == aiMessage.id }) {
                messages.remove(at: index)
            }
            try messageRepository.deleteMessage(id: aiMessage.id!)

            throw error
        }
    }

    /// Handles a chunk of streamed text
    private func handleStreamChunk(_ chunk: String, messageId: UUID) {
        streamingText += chunk

        // Update message in array for UI
        if let index = messages.firstIndex(where: { $0.id == messageId }) {
            // Note: We don't update Core Data on every chunk to avoid performance issues
            // Only the UI is updated incrementally
        }
    }

    /// Handles completion of streaming
    private func handleStreamComplete(
        result: Result<String, LLMError>,
        messageId: UUID,
        conversationId: UUID,
        providerType: LLMProviderType
    ) async {
        // Capture before modifying state so the reset at the end of this method
        // is reliable regardless of what the success/failure branches do.
        let wasSummaryTurn = (interviewPhase == .summary)

        // INVARIANT: keep isStreaming = false, streamingMessageId = nil, and
        // messages[index] = updatedMessage free of any `await` between them so
        // SwiftUI coalesces all three into a single render pass and avoids a
        // blank-flash where the streaming overlay disappears before the final
        // message text appears.
        isStreaming = false
        streamingMessageId = nil
        streamingText = ""

        switch result {
        case .success(let fullText):
            do {
                // Save complete message to Core Data
                try messageRepository.updateMessageContent(
                    id: messageId,
                    content: fullText,
                    complete: true,
                    tokenCount: nil // TODO: Extract token count from provider response
                )

                // Update conversation timestamp
                try conversationRepository.updateConversationTimestamp(
                    id: conversationId,
                    timestamp: Date()
                )

                // Log successful interaction
                try? auditLogger.log(
                    event: .aiStreamingCompleted,
                    userId: userId,
                    details: AuditEventDetails(
                        additionalInfo: [
                            "conversationId": conversationId.uuidString,
                            "provider": providerType.rawValue,
                            "success": "true"
                        ]
                    )
                )

                // Refresh message from Core Data to ensure consistency
                if let updatedMessage = try messageRepository.fetchMessage(id: messageId) {
                    if let index = messages.firstIndex(where: { $0.id == messageId }) {
                        messages[index] = updatedMessage
                    }
                }

            } catch {
                errorMessage = "Failed to save AI response: \(error.localizedDescription)"

                // Log save failure
                try? auditLogger.log(
                    event: .aiInteractionFailed,
                    userId: userId,
                    details: AuditEventDetails(
                        errorMessage: "Failed to save streamed response",
                        additionalInfo: [
                            "conversationId": conversationId.uuidString,
                            "error": error.localizedDescription
                        ]
                    )
                )
            }

        case .failure(let error):
            errorMessage = error.localizedDescription

            // Log failure
            try? auditLogger.log(
                event: .aiInteractionFailed,
                userId: userId,
                details: AuditEventDetails(
                    errorMessage: error.localizedDescription,
                    additionalInfo: [
                        "conversationId": conversationId.uuidString,
                        "provider": providerType.rawValue
                    ]
                )
            )

            // Remove failed message from UI and Core Data
            if let index = messages.firstIndex(where: { $0.id == messageId }) {
                messages.remove(at: index)
            }

            do {
                try messageRepository.deleteMessage(id: messageId)
            } catch {
                // Log deletion failure
                try? auditLogger.log(
                    event: .dataDeleted,
                    userId: userId,
                    details: AuditEventDetails(
                        errorMessage: "Failed to delete incomplete message",
                        additionalInfo: ["messageId": messageId.uuidString]
                    )
                )
            }
        }

        // If this completed the summary turn, return the phase to .gathering so
        // the patient can continue the interview after seeing the summary.
        if wasSummaryTurn {
            interviewPhase = .gathering
        }
    }

    /// Builds chat context from conversation messages.
    /// - Parameters:
    ///   - conversationId: UUID of the conversation.
    ///   - useSummaryPrompt: When `true`, injects `HealthcareSystemPrompt.summary`
    ///     (closing-turn variant). Defaults to `false`, which uses the normal
    ///     `HealthcareSystemPrompt.interview` gathering prompt. Phase 3 will pass
    ///     `true` when the conversation is in the summary phase; all other callers
    ///     use the default.
    /// - Returns: Array of ChatMessage for the LLM provider.
    /// - Throws: MessageRepositoryError
    private func buildChatContext(conversationId: UUID, useSummaryPrompt: Bool = false) throws -> [ChatMessage] {
        var chatMessages: [ChatMessage] = []

        // Select the prompt variant: summary for the closing turn, interview for all others.
        let systemPrompt = useSummaryPrompt
            ? HealthcareSystemPrompt.summary
            : HealthcareSystemPrompt.interview

        // Add system prompt first
        chatMessages.append(ChatMessage(
            role: .system,
            content: systemPrompt
        ))

        // Add all conversation messages (excluding the placeholder we just created)
        let allMessages = try messageRepository.fetchAllMessages(conversationId: conversationId)

        for message in allMessages {
            // Skip incomplete streaming messages
            guard message.streamingComplete else { continue }

            // Decrypt content
            let content = try messageRepository.decryptMessageContent(message)

            // Map role
            let role: MessageRole
            switch message.role {
            case "user":
                role = .user
            case "assistant":
                role = .assistant
            case "system":
                role = .system
            default:
                continue // Skip unknown roles
            }

            chatMessages.append(ChatMessage(role: role, content: content))
        }

        return chatMessages
    }

    /// Clears the current conversation and messages.
    ///
    /// Resets all in-memory state including `interviewPhase` so that the next
    /// conversation always starts in `.gathering` regardless of how the previous
    /// one ended.
    func clearCurrentConversation() {
        currentConversation = nil
        messages = []
        streamingText = ""
        streamingMessageId = nil
        isStreaming = false
        errorMessage = nil
        currentProvider = nil
        interviewPhase = .gathering
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
