//
//  AIConversationService.swift
//  HouseCall
//
//  AI Conversation Service - Business Logic Layer
//  Orchestrates LLM provider interactions with conversation persistence
//

import Foundation
import Combine

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

    // MARK: - Dependencies

    private let conversationRepository: ConversationRepositoryProtocol
    private let messageRepository: MessageRepositoryProtocol
    private let providerConfigManager: LLMProviderConfigManager
    private let auditLogger: AuditLogger

    /// Current user ID (authenticated user)
    private let userId: UUID

    /// Active LLM provider for streaming requests
    private var currentProvider: LLMProvider?

    // MARK: - Initialization

    init(
        userId: UUID,
        conversationRepository: ConversationRepositoryProtocol,
        messageRepository: MessageRepositoryProtocol,
        providerConfigManager: LLMProviderConfigManager = .shared,
        auditLogger: AuditLogger = .shared
    ) {
        self.userId = userId
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
        self.providerConfigManager = providerConfigManager
        self.auditLogger = auditLogger
    }

    // MARK: - Conversation Management

    /// Creates a new conversation with the specified provider
    /// - Parameter provider: LLM provider type to use (defaults to active provider)
    /// - Returns: Created Conversation entity
    /// - Throws: ConversationRepositoryError or other errors
    func createConversation(provider: LLMProviderType? = nil) async throws -> Conversation {
        let selectedProvider = provider ?? providerConfigManager.getActiveProvider()

        // Verify provider is configured
        guard providerConfigManager.isProviderConfigured(selectedProvider) else {
            throw LLMError.notConfigured
        }

        // Create conversation in repository
        let conversation = try conversationRepository.createConversation(
            userId: userId,
            provider: selectedProvider,
            title: nil
        )

        // Log conversation creation
        auditLogger.log(
            eventType: .conversationCreated,
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
            auditLogger.log(
                eventType: .unauthorizedAccess,
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
        auditLogger.log(
            eventType: .conversationAccessed,
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

    /// Switches the LLM provider for a conversation
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - newProvider: New provider type to use
    /// - Throws: ConversationRepositoryError, LLMError
    func switchProvider(conversationId: UUID, to newProvider: LLMProviderType) async throws {
        // Verify provider is configured
        guard providerConfigManager.isProviderConfigured(newProvider) else {
            throw LLMError.notConfigured
        }

        // Update conversation provider
        try conversationRepository.updateConversationProvider(id: conversationId, provider: newProvider)

        // Create system message indicating switch
        let systemMessage = try messageRepository.createMessage(
            conversationId: conversationId,
            role: .system,
            content: "Provider switched to \(newProvider.displayName)",
            streamingComplete: true
        )

        // Log provider switch
        auditLogger.log(
            eventType: .conversationProviderSwitched,
            userId: userId,
            details: AuditEventDetails(
                additionalInfo: [
                    "conversationId": conversationId.uuidString,
                    "newProvider": newProvider.rawValue
                ]
            )
        )

        // Update current conversation if it's the active one
        if currentConversation?.id == conversationId {
            currentConversation = try conversationRepository.fetchConversation(id: conversationId)
            messages.append(systemMessage)
        }

        // Clear current provider to force recreation with new type
        currentProvider = nil
    }

    // MARK: - Message Handling

    /// Sends a message and receives a streaming AI response
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - content: User's message content
    /// - Throws: Various errors from repositories and LLM providers
    func sendMessage(conversationId: UUID, content: String) async throws {
        // Clear any previous errors
        errorMessage = nil

        // Validate content
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MessageRepositoryError.invalidContent
        }

        // Ensure conversation exists
        guard let conversation = try conversationRepository.fetchConversation(id: conversationId) else {
            throw ConversationRepositoryError.conversationNotFound
        }

        // Verify user owns this conversation
        guard conversation.userId == userId else {
            throw ConversationRepositoryError.conversationNotFound
        }

        // Save user message
        let userMessage = try messageRepository.createMessage(
            conversationId: conversationId,
            role: .user,
            content: content,
            streamingComplete: true
        )

        // Log message creation
        auditLogger.log(
            eventType: .messageCreated,
            userId: userId,
            details: AuditEventDetails(
                additionalInfo: [
                    "conversationId": conversationId.uuidString,
                    "role": MessageRole.user.rawValue
                ]
            )
        )

        // Update conversation title if this is the first message
        if messages.isEmpty {
            let title = String(content.prefix(50))
            try conversationRepository.updateConversationTitle(id: conversationId, title: title)
        }

        // Update conversation timestamp
        try conversationRepository.updateConversationTimestamp(id: conversationId, timestamp: Date())

        // Add user message to UI
        messages.append(userMessage)

        // Get or create provider instance
        let providerType = LLMProviderType(rawValue: conversation.llmProvider ?? "openai") ?? .openai
        guard let provider = providerConfigManager.createProvider(type: providerType) else {
            throw LLMError.notConfigured
        }

        // Verify provider is configured
        guard provider.isConfigured else {
            throw LLMError.notConfigured
        }

        self.currentProvider = provider

        // Create placeholder AI message
        let aiMessage = try messageRepository.createMessage(
            conversationId: conversationId,
            role: .assistant,
            content: "",
            streamingComplete: false
        )

        // Add to UI
        messages.append(aiMessage)
        streamingMessageId = aiMessage.id
        streamingText = ""
        isStreaming = true

        // Build conversation context
        let chatMessages = try buildChatContext(conversationId: conversationId)

        // Log AI interaction start
        auditLogger.log(
            eventType: .aiStreamingStarted,
            userId: userId,
            details: AuditEventDetails(
                additionalInfo: [
                    "conversationId": conversationId.uuidString,
                    "provider": providerType.rawValue
                ]
            )
        )

        // Stream completion
        do {
            try await provider.streamCompletion(
                messages: chatMessages,
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
            // Handle streaming errors
            isStreaming = false
            streamingMessageId = nil

            // Log failure
            auditLogger.log(
                eventType: .aiInteractionFailed,
                userId: userId,
                details: AuditEventDetails(
                    errorMessage: error.localizedDescription,
                    additionalInfo: [
                        "conversationId": conversationId.uuidString,
                        "provider": providerType.rawValue
                    ]
                )
            )

            // Remove incomplete message
            if let index = messages.firstIndex(where: { $0.id == aiMessage.id }) {
                messages.remove(at: index)
            }
            try messageRepository.deleteMessage(id: aiMessage.id!)

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
            auditLogger.log(
                eventType: .aiStreamingInterrupted,
                userId: userId,
                details: AuditEventDetails(
                    message: "User cancelled streaming",
                    additionalInfo: ["conversationId": conversationId.uuidString]
                )
            )
        }
    }

    // MARK: - Private Methods

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
        isStreaming = false
        streamingMessageId = nil

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
                auditLogger.log(
                    eventType: .aiStreamingCompleted,
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
                auditLogger.log(
                    eventType: .aiInteractionFailed,
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
            auditLogger.log(
                eventType: .aiInteractionFailed,
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
                auditLogger.log(
                    eventType: .dataDeleted,
                    userId: userId,
                    details: AuditEventDetails(
                        errorMessage: "Failed to delete incomplete message",
                        additionalInfo: ["messageId": messageId.uuidString]
                    )
                )
            }
        }

        streamingText = ""
    }

    /// Builds chat context from conversation messages
    /// - Parameter conversationId: UUID of the conversation
    /// - Returns: Array of ChatMessage for LLM provider
    /// - Throws: MessageRepositoryError
    private func buildChatContext(conversationId: UUID) throws -> [ChatMessage] {
        var chatMessages: [ChatMessage] = []

        // Add system prompt first
        chatMessages.append(ChatMessage(
            role: .system,
            content: HealthcareSystemPrompt.default
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

    /// Clears the current conversation and messages
    func clearCurrentConversation() {
        currentConversation = nil
        messages = []
        streamingText = ""
        streamingMessageId = nil
        isStreaming = false
        errorMessage = nil
        currentProvider = nil
    }
}
