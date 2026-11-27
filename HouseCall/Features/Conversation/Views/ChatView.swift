//
//  ChatView.swift
//  HouseCall
//
//  Chat Interface - Main conversation view with message list and input
//  Supports streaming AI responses and real-time message display
//

import SwiftUI
import CoreData

/// Main chat view for displaying and interacting with AI conversations
struct ChatView: View {
    @ObservedObject var viewModel: ConversationViewModel

    @State private var messageText: String = ""
    @State private var showError: Bool = false
    @State private var showProfile: Bool = false
    @State private var showSignIn: Bool = false
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
                                isStreaming: false
                            )
                            .id(message.id)
                        }

                        // Physician-approved recommendation cards delivered via
                        // WebSocket.  Cards are keyed on the recommendation's
                        // server ID so duplicate events are deduplicated by
                        // ForEach identity.  Rendered after any inline messages
                        // so they appear at the bottom of the thread.
                        ForEach(viewModel.recommendationCards) { card in
                            RecommendationCard(model: card)
                                .id("rec-\(card.id)")
                        }

                        if viewModel.isAwaitingReply {
                            WaitingForReplyIndicator()
                                .id("awaiting-reply")
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .onChange(of: viewModel.messages.count) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.isAwaitingReply) {
                    scrollToBottom(proxy: proxy)
                }
                .onChange(of: viewModel.recommendationCards.count) {
                    scrollToBottom(proxy: proxy)
                }
            }

            Divider()

            // MARK: - Error Banner
            if viewModel.isReadOnly {
                signInBanner
            } else if let errorMessage = viewModel.errorMessage {
                errorBanner(message: errorMessage)
            }

            // MARK: - Input Area
            inputArea
        }
        .navigationTitle(conversationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    showProfile = true
                }) {
                    Image(systemName: "person.circle")
                        .accessibilityLabel("Profile")
                }
                .accessibilityIdentifier("profileButton")
            }
        }
        .sheet(isPresented: $showProfile) {
            ProfileView()
        }
        .sheet(isPresented: $showSignIn) {
            CloudSignInSheet(viewModel: viewModel)
        }
        .onAppear {
            viewModel.loadMessages()
        }
    }

    // MARK: - Subviews

    private var inputArea: some View {
        HStack(spacing: 12) {
            // Text input field
            TextField("Type your message...", text: $messageText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .disabled(viewModel.isReadOnly)
                .lineLimit(1...5)
                .accessibilityIdentifier("chatMessageInput")

            // Clear button
            if !messageText.isEmpty && !viewModel.isReadOnly {
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
            .accessibilityIdentifier("chatSendButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemBackground))
    }

    private var signInBanner: some View {
        HStack {
            Image(systemName: "lock.fill")
                .foregroundColor(.orange)
                .accessibilityHidden(true)

            Text("Sign in to send messages")
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            Button("Sign in") { showSignIn = true }
                .font(.subheadline)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Sign in to send messages")
                .accessibilityHint("Opens a password prompt to reconnect")
                .accessibilityIdentifier("chatSignInButton")
        }
        .padding()
        .background(Color(.systemYellow).opacity(0.2))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Chat is read-only. Sign in to send messages.")
        .accessibilityIdentifier("chatSignInBanner")
    }

    private func errorBanner(message: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.primary)

            Spacer()

            // Retry button for certain errors
            if message.contains("connect") || message.contains("timeout") {
                Button("Retry") {
                    viewModel.retryLastMessage()
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }

            Button(action: { viewModel.clearError() }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.systemYellow).opacity(0.2))
        .cornerRadius(8)
        .padding(.horizontal)
        .padding(.vertical, 8)
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

    private var canSend: Bool {
        !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isReadOnly
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
                if let lastMessage = viewModel.messages.last {
                    proxy.scrollTo(lastMessage.id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Waiting indicator

/// Typing dots shown between sending a message and the agent's reply.
private struct WaitingForReplyIndicator: View {
    @State private var animate = false

    var body: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3) { index in
                    Circle()
                        .fill(Color.gray)
                        .frame(width: 8, height: 8)
                        .opacity(animate ? 1.0 : 0.3)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.2),
                            value: animate
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.systemGray5))
            .cornerRadius(20)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onAppear { animate = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Waiting for a reply")
        .accessibilityIdentifier("chatAwaitingReplyIndicator")
    }
}

// MARK: - Sign-in sheet

/// Asks for the password (email prefilled from the current session) and
/// re-authenticates with the Core API. Dismisses itself on success.
private struct CloudSignInSheet: View {
    @ObservedObject var viewModel: ConversationViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var password: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    // Display only: sign-in is locked to the current patient.
                    Text(viewModel.signInEmail)
                        .foregroundColor(.secondary)
                        .accessibilityLabel("Email \(viewModel.signInEmail), cannot be changed")
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("chatSignInPassword")
                }
                if let error = viewModel.signInError {
                    Text(error).foregroundColor(.red).font(.footnote)
                }
            }
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Sign in") {
                        Task {
                            if await viewModel.signIn(password: password) { dismiss() }
                        }
                    }
                    .disabled(password.isEmpty || viewModel.isSigningIn)
                    .accessibilityLabel("Sign in")
                    .accessibilityIdentifier("chatSignInSubmit")
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

    NavigationStack {
        ChatView(viewModel: viewModel)
    }
}
