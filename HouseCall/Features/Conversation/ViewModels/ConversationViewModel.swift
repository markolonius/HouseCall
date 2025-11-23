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

    /// Current LLM error (for enhanced error handling)
    @Published private(set) var currentError: LLMError?

    /// Rate limit countdown timer (seconds remaining)
    @Published private(set) var rateLimitCountdown: Int?

    // MARK: - Dependencies

    let conversationRepository: ConversationRepositoryProtocol
    let messageRepository: MessageRepositoryProtocol
    private let aiService: AIConversationService

    private let userId: UUID
    private let conversationId: UUID
    private var cancellables = Set<AnyCancellable>()

    // Last sent message for retry functionality
    private var lastMessageContent: String?

    // Rate limit timer
    private var rateLimitTimer: Timer?

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
        currentError = nil
        rateLimitCountdown = nil
        rateLimitTimer?.invalidate()
        rateLimitTimer = nil
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
            currentError = llmError
            errorMessage = llmError.userFriendlyMessage

            // Start countdown for rate limit errors
            if let seconds = llmError.retryAfterSeconds {
                startRateLimitCountdown(seconds: seconds)
            }
        } else if let _ = error as? ConversationRepositoryError {
            errorMessage = "Unable to load conversation. Please try again."
            currentError = nil
        } else if let _ = error as? MessageRepositoryError {
            errorMessage = "Unable to save message. Please try again."
            currentError = nil
        } else {
            errorMessage = "An unexpected error occurred. Please try again."
            currentError = nil
        }

        // Log error without PHI
        print("ConversationViewModel error: \(error.localizedDescription)")
    }

    /// Start countdown timer for rate limit errors
    private func startRateLimitCountdown(seconds: Int) {
        rateLimitCountdown = seconds
        rateLimitTimer?.invalidate()

        rateLimitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else {
                timer.invalidate()
                return
            }

            Task { @MainActor in
                if let countdown = self.rateLimitCountdown, countdown > 0 {
                    self.rateLimitCountdown = countdown - 1

                    // Update error message with new countdown
                    self.errorMessage = "Rate limit exceeded. Wait \(countdown - 1)s."
                } else {
                    // Countdown complete - clear error and auto-retry if there's a last message
                    timer.invalidate()
                    self.rateLimitTimer = nil
                    self.rateLimitCountdown = nil
                    self.clearError()

                    // Auto-retry the last message
                    if let lastContent = self.lastMessageContent {
                        await self.sendMessage(content: lastContent)
                    }
                }
            }
        }
    }
}

