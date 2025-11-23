//
//  ChatView.swift
//  HouseCall
//
//  Chat Interface - Main conversation view with message list and input
//  Supports streaming AI responses and real-time message display
//

import SwiftUI

/// Main chat view for displaying and interacting with AI conversations
struct ChatView: View {
    @ObservedObject var viewModel: ConversationViewModel
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    @State private var messageText: String = ""
    @State private var showError: Bool = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Messages List
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Messages
                        ForEach(viewModel.messages, id: \.id) { message in
                            MessageBubbleView(
                                message: message,
                                messageRepository: viewModel.messageRepository,
                                isStreaming: viewModel.isStreaming && message.id == viewModel.streamingMessageId
                            )
                            .id(message.id)
                        }

                        // Streaming message (if not yet in messages array)
                        if viewModel.isStreaming && !viewModel.streamingText.isEmpty {
                            streamingBubbleView
                                .id("streaming")
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .onChange(of: viewModel.messages.count) { _ in
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.streamingText) { _ in
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()

            // MARK: - Network Status Banner
            if !networkMonitor.isConnected {
                networkStatusBanner
            }

            // MARK: - Error Banner
            if let errorMessage = viewModel.errorMessage {
                errorBanner(message: errorMessage)
            }

            // MARK: - Input Area
            inputArea
        }
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                providerBadge
            }
        }
        .onAppear {
            viewModel.loadMessages()
        }
    }

    // MARK: - Subviews

    private var streamingBubbleView: some View {
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(viewModel.streamingText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray5))
                    .foregroundColor(.primary)
                    .cornerRadius(20)

                // Typing indicator
                HStack(spacing: 4) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(Color.gray)
                            .frame(width: 6, height: 6)
                            .animation(
                                Animation
                                    .easeInOut(duration: 0.6)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.2),
                                value: index
                            )
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }

    private var inputArea: some View {
        HStack(spacing: 12) {
            // Text input field
            TextField("Type your message...", text: $messageText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .disabled(viewModel.isStreaming)
                .lineLimit(1...5)

            // Clear button
            if !messageText.isEmpty && !viewModel.isStreaming {
                Button(action: clearMessage) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }

            // Send button
            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundColor(canSend ? .blue : .gray)
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
        .overlay(
            // "AI is responding..." label
            viewModel.isStreaming ?
                Text("AI is responding...")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.bottom, 80)
                : nil,
            alignment: .bottom
        )
    }

    private func errorBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: errorIcon)
                    .foregroundColor(errorColor)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.primary)

                Spacer()

                Button(action: { viewModel.clearError() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }

            // Action buttons row
            HStack(spacing: 12) {
                // Retry button for retryable errors
                if viewModel.currentError?.isRetryable == true && viewModel.rateLimitCountdown == nil {
                    Button(action: {
                        viewModel.clearError()
                        viewModel.retryLastMessage()
                    }) {
                        HStack {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }

                // Settings button for configuration errors
                if viewModel.currentError?.needsConfiguration == true {
                    Button(action: {
                        // Navigate to settings (future implementation)
                        // For now, just show an alert
                        print("Navigate to LLM provider settings")
                    }) {
                        HStack {
                            Image(systemName: "gear")
                            Text("Settings")
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(8)
                    }
                }

                // Countdown timer for rate limit
                if let countdown = viewModel.rateLimitCountdown, countdown > 0 {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Auto-retry in \(countdown)s")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color(.systemGray5))
                    .cornerRadius(8)
                }

                Spacer()
            }
        }
        .padding()
        .background(errorBackgroundColor)
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var networkStatusBanner: some View {
        HStack {
            Image(systemName: "wifi.slash")
                .foregroundColor(.orange)

            Text("No internet connection. Messages saved locally.")
                .font(.caption)
                .foregroundColor(.primary)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(.systemOrange).opacity(0.15))
    }

    // MARK: - Error UI Helpers

    private var errorIcon: String {
        guard let error = viewModel.currentError else {
            return "exclamationmark.triangle.fill"
        }

        switch error {
        case .authenticationFailed, .notConfigured, .invalidConfiguration:
            return "key.slash"
        case .networkError, .connectionLost:
            return "wifi.slash"
        case .rateLimit:
            return "clock.fill"
        case .timeout:
            return "clock.badge.exclamationmark"
        default:
            return "exclamationmark.triangle.fill"
        }
    }

    private var errorColor: Color {
        guard let error = viewModel.currentError else {
            return .orange
        }

        switch error {
        case .authenticationFailed, .notConfigured, .invalidConfiguration:
            return .red
        case .rateLimit:
            return .orange
        default:
            return .orange
        }
    }

    private var errorBackgroundColor: Color {
        guard let error = viewModel.currentError else {
            return Color(.systemYellow).opacity(0.2)
        }

        switch error {
        case .authenticationFailed, .notConfigured, .invalidConfiguration:
            return Color(.systemRed).opacity(0.15)
        case .rateLimit:
            return Color(.systemOrange).opacity(0.15)
        default:
            return Color(.systemYellow).opacity(0.2)
        }
    }

    private var providerBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: providerIcon)
                .font(.caption)
            Text(providerName)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(12)
    }

    // MARK: - Computed Properties

    private var conversationTitle: String {
        guard let conversation = viewModel.currentConversation else {
            return "New Chat"
        }

        do {
            let title = try viewModel.conversationRepository.decryptConversationTitle(conversation)
            return title.isEmpty ? "Chat" : String(title.prefix(30))
        } catch {
            return "Chat"
        }
    }

    private var providerName: String {
        guard let conversation = viewModel.currentConversation else {
            return "OpenAI"
        }
        return conversation.llmProvider?.capitalized ?? "OpenAI"
    }

    private var providerIcon: String {
        switch providerName.lowercased() {
        case "openai":
            return "brain.head.profile"
        case "claude":
            return "sparkles"
        case "custom":
            return "server.rack"
        default:
            return "cpu"
        }
    }

    private var canSend: Bool {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let notStreaming = !viewModel.isStreaming
        let notRateLimited = viewModel.rateLimitCountdown == nil

        return hasText && notStreaming && notRateLimited
    }

    // MARK: - Actions

    private func sendMessage() {
        let trimmedText = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        Task {
            await viewModel.sendMessage(content: trimmedText)
        }

        // Clear input immediately for better UX
        messageText = ""
        isInputFocused = true
    }

    private func clearMessage() {
        messageText = ""
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                if viewModel.isStreaming {
                    proxy.scrollTo("streaming", anchor: .bottom)
                } else if let lastMessage = viewModel.messages.last {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let persistence = PersistenceController.preview
    let conversationRepo = CoreDataConversationRepository(context: persistence.container.viewContext)
    let messageRepo = CoreDataMessageRepository(context: persistence.container.viewContext)

    // Create preview conversation
    let userId = UUID()
    let conversation = try? conversationRepo.createConversation(
        userId: userId,
        provider: .openai,
        title: "Health Consultation"
    )

    let viewModel = ConversationViewModel(
        userId: userId,
        conversationId: conversation?.id ?? UUID(),
        conversationRepository: conversationRepo,
        messageRepository: messageRepo
    )

    return NavigationStack {
        ChatView(viewModel: viewModel)
    }
}
