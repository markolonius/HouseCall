//
//  MessageBubbleView.swift
//  HouseCall
//
//  Message Bubble Component - Displays individual chat messages
//  Supports user (right-aligned, blue) and AI (left-aligned, gray) styling
//

import SwiftUI

/// Displays a single message bubble in the chat interface
struct MessageBubbleView: View {
    let message: Message
    let messageRepository: MessageRepositoryProtocol
    let isStreaming: Bool

    @State private var decryptedContent: String = ""
    @State private var showTimestamp: Bool = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUserMessage {
                Spacer()
            }

            VStack(alignment: isUserMessage ? .trailing : .leading, spacing: 4) {
                // Message bubble
                Text(decryptedContent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(bubbleColor)
                    .foregroundColor(textColor)
                    .cornerRadius(20)
                    .textSelection(.enabled)

                // Timestamp (shown on tap or long press)
                if showTimestamp {
                    Text(formattedTimestamp)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                }

                // Streaming indicator
                if isStreaming && !isUserMessage {
                    HStack(spacing: 4) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(Color.gray)
                                .frame(width: 6, height: 6)
                                .opacity(typingAnimation(index: index))
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
        }
        .onChange(of: message.encryptedContent) { _ in
            // Update when streaming adds new content
            decryptMessage()
        }
    }

    // MARK: - Computed Properties

    private var isUserMessage: Bool {
        message.role == "user"
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

    private func typingAnimation(index: Int) -> Double {
        let animation = Animation
            .easeInOut(duration: 0.6)
            .repeatForever(autoreverses: true)
            .delay(Double(index) * 0.2)

        return withAnimation(animation) {
            0.3
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
