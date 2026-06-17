//
//  MessageBubbleView.swift
//  HouseCall
//
//  Message Bubble Component - Displays individual chat messages
//  Supports user (right-aligned, blue) and AI (left-aligned, gray) styling
//

import SwiftUI
import CoreData

/// Displays a single message bubble in the chat interface
struct MessageBubbleView: View {
    let message: Message
    let messageRepository: MessageRepositoryProtocol
    let isStreaming: Bool
    /// Live text passed in from the ViewModel while this message is being streamed.
    /// When non-nil and non-empty this is shown instead of the (not-yet-persisted)
    /// decrypted encrypted content, so tokens appear in real time.
    var streamingText: String? = nil

    @State private var decryptedContent: String = ""
    @State private var showTimestamp: Bool = false
    /// Drives the repeating opacity animation for the 3-dot typing indicator.
    @State private var showDots: Bool = false

    /// Returns the text to display: live streamingText during streaming, otherwise
    /// the persisted-and-decrypted content.
    private var displayContent: String {
        if let live = streamingText, !live.isEmpty {
            return live
        }
        return decryptedContent
    }

    var body: some View {
        // System messages are displayed differently (centered)
        if isSystemMessage {
            systemMessageView
        } else {
            regularMessageView
        }
    }

    // MARK: - Subviews

    private var systemMessageView: some View {
        HStack {
            Spacer()
            Text(displayContent)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color(.systemGray6))
                .cornerRadius(12)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            decryptMessage()
        }
    }

    private var regularMessageView: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUserMessage {
                Spacer()
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
                // Message bubble — when the assistant bubble is streaming but no
                // token has arrived yet, show the typing indicator inside the
                // bubble so there is never an empty/zero-height gray box.
                Group {
                    if isStreaming && !isUserMessage && displayContent.isEmpty {
                        inlineDotIndicator
                    } else if isUserMessage {
                        // User messages render as plain text — never interpret
                        // patient input as markup.
                        Text(displayContent)
                            .textSelection(.enabled)
                    } else {
                        // Assistant messages render as Markdown (headings, lists,
                        // code blocks, bold/italic/links via AttributedString).
                        MarkdownText(content: displayContent)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(bubbleColor)
                .foregroundColor(textColor)
                .cornerRadius(20)

                // Timestamp (shown on tap or long press)
                if showTimestamp {
                    Text(formattedTimestamp)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                }

                // Below-bubble streaming dots — shown once tokens are arriving
                // so the user knows the response is still in progress.
                if isStreaming && !isUserMessage && !displayContent.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 6, height: 6)
                                .opacity(showDots ? 1.0 : 0.3)
                                .animation(
                                    .easeInOut(duration: 0.6)
                                        .repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2),
                                    value: showDots
                                )
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }
            .onTapGesture {
                withAnimation {
                    showTimestamp.toggle()
                }
            }

            if !isUserMessage {
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear {
            decryptMessage()
            // Start dot animation if this bubble is already streaming on appear.
            if isStreaming && !isUserMessage {
                showDots = true
            }
        }
        .onChange(of: message.encryptedContent) {
            // Update when streaming adds new content
            decryptMessage()
        }
        .onChange(of: isStreaming) {
            // Start animation when the bubble transitions into streaming state.
            if isStreaming && !isUserMessage {
                showDots = true
            }
        }
    }

    /// Three animated dots rendered inside the assistant bubble before the
    /// first SSE token arrives.
    private var inlineDotIndicator: some View {
        HStack(spacing: 6) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(Color.gray.opacity(0.7))
                    .frame(width: 8, height: 8)
                    .opacity(showDots ? 1.0 : 0.3)
                    .animation(
                        .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.2),
                        value: showDots
                    )
            }
        }
        .onAppear { showDots = true }
    }

    // MARK: - Computed Properties

    private var isUserMessage: Bool {
        message.role == "user"
    }

    private var isSystemMessage: Bool {
        message.role == "system"
    }

    private var bubbleColor: Color {
        isUserMessage ? Color.blue : Color(.systemGray5)
    }

    private var textColor: Color {
        isUserMessage ? .white : .primary
    }

    private var formattedTimestamp: String {
        guard let timestamp = message.timestamp else { return "" }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: timestamp)
    }

    // MARK: - Private Methods

    private func decryptMessage() {
        do {
            decryptedContent = try messageRepository.decryptMessageContent(message)
        } catch {
            decryptedContent = "[Unable to decrypt message]"
        }
    }
}

// MARK: - Preview

#Preview {
    let persistence = PersistenceController.preview
    let repository = CoreDataMessageRepository(context: persistence.container.viewContext)

    VStack(spacing: 16) {
        // User message example
        if let userMessage = createPreviewMessage(role: "user", content: "I have a headache and fever", in: persistence) {
            MessageBubbleView(
                message: userMessage,
                messageRepository: repository,
                isStreaming: false
            )
        }

        // AI message example
        if let aiMessage = createPreviewMessage(role: "assistant", content: "I understand you're experiencing a headache and fever. Can you tell me how long you've had these symptoms?", in: persistence) {
            MessageBubbleView(
                message: aiMessage,
                messageRepository: repository,
                isStreaming: false
            )
        }

        // Streaming AI message example
        if let streamingMessage = createPreviewMessage(role: "assistant", content: "Based on your symptoms...", in: persistence) {
            MessageBubbleView(
                message: streamingMessage,
                messageRepository: repository,
                isStreaming: true
            )
        }
    }
    .padding()
}

// MARK: - Preview Helper

private func createPreviewMessage(role: String, content: String, in persistence: PersistenceController) -> Message? {
    let context = persistence.container.viewContext
    let message = Message(context: context)
    message.id = UUID()
    message.conversationId = UUID()
    message.role = role
    message.timestamp = Date()
    message.streamingComplete = true
    message.tokenCount = 0

    // Encrypt content for preview
    do {
        let userId = UUID()
        let encrypted = try EncryptionManager.shared.encryptString(content, for: userId)
        message.encryptedContent = encrypted
    } catch {
        return nil
    }

    return message
}
