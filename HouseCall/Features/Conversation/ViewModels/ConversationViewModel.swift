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

    /// Whether an AI response is currently streaming
    @Published private(set) var isStreaming: Bool = false

    /// Current error message to display in UI
    @Published private(set) var errorMessage: String?

    /// Current streaming response text
    @Published private(set) var streamingText: String = ""

    /// ID of the message currently being streamed
    @Published private(set) var streamingMessageId: UUID?

    // MARK: - Dependencies

    let conversationRepository: ConversationRepositoryProtocol
    let messageRepository: MessageRepositoryProtocol
    private let aiService: AIConversationService

    private let userId: UUID
    private let conversationId: UUID
    private var cancellables = Set<AnyCancellable>()

    // Last sent message for retry functionality
    private var lastMessageContent: String?

    // MARK: - Initialization

    init(
        userId: UUID,
        conversationId: UUID,
        conversationRepository: ConversationRepositoryProtocol,
        messageRepository: MessageRepositoryProtocol,
        aiService: AIConversationService? = nil
    ) {
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
    func loadMessages() {
        Task {
            do {
                let fetchedMessages = try messageRepository.fetchAllMessages(conversationId: conversationId)
                self.messages = fetchedMessages

                // Load conversation metadata
                if let conversation = try conversationRepository.fetchConversation(id: conversationId) {
                    self.currentConversation = conversation
                }
            } catch {
                handleError(error)
            }
        }
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

    /// Switch to a different LLM provider
    /// - Parameter provider: The new provider to use
    func switchProvider(to provider: LLMProviderType) async {
        do {
            try await aiService.switchProvider(conversationId: conversationId, to: provider)
            // Reload messages to show the provider switch system message
            loadMessages()
        } catch {
            handleError(error)
        }
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

        // Observe streaming state
        aiService.$isStreaming
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isStreaming in
                self?.isStreaming = isStreaming
            }
            .store(in: &cancellables)

        // Observe streaming text
        aiService.$streamingText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.streamingText = text
            }
            .store(in: &cancellables)

        // Observe streaming message ID
        aiService.$streamingMessageId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] messageId in
                self?.streamingMessageId = messageId
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
    }

    private func handleError(_ error: Error) {
        // Convert technical errors to user-friendly messages
        if let llmError = error as? LLMError {
            errorMessage = llmError.userFriendlyMessage
        } else if let _ = error as? ConversationRepositoryError {
            errorMessage = "Unable to load conversation. Please try again."
        } else if let _ = error as? MessageRepositoryError {
            errorMessage = "Unable to save message. Please try again."
        } else {
            errorMessage = "An unexpected error occurred. Please try again."
        }

        // Log error without PHI
        print("ConversationViewModel error: \(error.localizedDescription)")
    }
}

// MARK: - LLMError Extension

extension LLMError {
    var userFriendlyMessage: String {
        switch self {
        case .notConfigured:
            return "AI service not configured. Please check your settings."
        case .authentication:
            return "API authentication failed. Please check your API key in settings."
        case .network:
            return "Unable to connect to AI service. Please check your internet connection."
        case .rateLimit:
            return "Too many requests. Please wait a moment and try again."
        case .timeout:
            return "Request timed out. Please try again."
        case .invalidResponse:
            return "Received an invalid response from AI service."
        case .providerError(let message):
            return "AI service error: \(message)"
        case .streamingCancelled:
            return "AI response was cancelled."
        case .unknown:
            return "An unexpected error occurred. Please try again."
        }
    }
}
