//
//  ConversationListView.swift
//  HouseCall
//
//  Conversation List - Displays all user conversations
//  Allows creating new chats and navigating to existing conversations
//

import SwiftUI

/// View displaying a list of all conversations for the current user
struct ConversationListView: View {
    @StateObject private var viewModel: ConversationListViewModel
    @State private var showingNewChatOptions = false

    init(userId: UUID, conversationRepository: ConversationRepositoryProtocol, messageRepository: MessageRepositoryProtocol) {
        _viewModel = StateObject(wrappedValue: ConversationListViewModel(
            userId: userId,
            conversationRepository: conversationRepository,
            messageRepository: messageRepository
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if viewModel.conversations.isEmpty {
                    emptyStateView
                } else {
                    conversationList
                }
            }
            .navigationTitle("Conversations")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    newChatButton
                }
            }
            .onAppear {
                viewModel.loadConversations()
            }
            .refreshable {
                viewModel.loadConversations()
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK", role: .cancel) {
                    viewModel.clearError()
                }
            } message: {
                Text(viewModel.errorMessage ?? "An error occurred")
            }
        }
    }

    // MARK: - Subviews

    private var conversationList: some View {
        List {
            ForEach(viewModel.conversations, id: \.id) { conversation in
                NavigationLink(destination: destinationView(for: conversation)) {
                    ConversationRowView(
                        conversation: conversation,
                        conversationRepository: viewModel.conversationRepository
                    )
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        viewModel.deleteConversation(conversation)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Conversations")
                .font(.title2)
                .fontWeight(.semibold)

            Text("Start a new conversation with your AI health assistant")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: { viewModel.createNewConversation() }) {
                Label("New Conversation", systemImage: "plus.circle.fill")
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .background(Color.blue)
                    .cornerRadius(12)
            }
            .padding(.top, 20)
        }
    }

    private var newChatButton: some View {
        Button(action: { viewModel.createNewConversation() }) {
            Image(systemName: "square.and.pencil")
                .font(.title3)
        }
    }

    private func destinationView(for conversation: Conversation) -> some View {
        let chatViewModel = ConversationViewModel(
            userId: viewModel.userId,
            conversationId: conversation.id!,
            conversationRepository: viewModel.conversationRepository,
            messageRepository: viewModel.messageRepository
        )

        return ChatView(viewModel: chatViewModel)
    }
}

// MARK: - Conversation Row View

struct ConversationRowView: View {
    let conversation: Conversation
    let conversationRepository: ConversationRepositoryProtocol

    @State private var title: String = ""

    var body: some View {
        HStack(spacing: 12) {
            // Provider icon
            providerIcon
                .frame(width: 40, height: 40)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                // Conversation title
                Text(title.isEmpty ? "New Chat" : title)
                    .font(.headline)
                    .lineLimit(1)

                // Last updated timestamp
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                    Text(formattedDate)
                        .font(.caption)
                }
                .foregroundColor(.secondary)
            }

            Spacer()

            // Chevron
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 8)
        .onAppear {
            loadTitle()
        }
    }

    // MARK: - Computed Properties

    private var providerIcon: some View {
        let iconName: String
        let provider = conversation.llmProvider?.lowercased() ?? "openai"

        switch provider {
        case "openai":
            iconName = "brain.head.profile"
        case "claude":
            iconName = "sparkles"
        case "custom":
            iconName = "server.rack"
        default:
            iconName = "cpu"
        }

        return Image(systemName: iconName)
            .font(.title3)
            .foregroundColor(.blue)
    }

    private var formattedDate: String {
        guard let date = conversation.updatedAt else {
            return ""
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Private Methods

    private func loadTitle() {
        do {
            let decryptedTitle = try conversationRepository.decryptConversationTitle(conversation)
            title = decryptedTitle.isEmpty ? "Chat" : String(decryptedTitle.prefix(50))
        } catch {
            title = "Chat"
        }
    }
}

// MARK: - Conversation List ViewModel

@MainActor
class ConversationListViewModel: ObservableObject {
    @Published private(set) var conversations: [Conversation] = []
    @Published var showError: Bool = false
    @Published var errorMessage: String?

    let userId: UUID
    let conversationRepository: ConversationRepositoryProtocol
    let messageRepository: MessageRepositoryProtocol

    private let auditLogger: AuditLogger = .shared

    init(
        userId: UUID,
        conversationRepository: ConversationRepositoryProtocol,
        messageRepository: MessageRepositoryProtocol
    ) {
        self.userId = userId
        self.conversationRepository = conversationRepository
        self.messageRepository = messageRepository
    }

    func loadConversations() {
        do {
            conversations = try conversationRepository.fetchConversations(userId: userId)
        } catch {
            handleError(error, message: "Unable to load conversations")
        }
    }

    func createNewConversation() {
        Task {
            do {
                // Create new conversation with default provider
                let conversation = try conversationRepository.createConversation(
                    userId: userId,
                    provider: .openai,
                    title: nil
                )

                // Log conversation creation
                auditLogger.log(
                    eventType: .conversationCreated,
                    userId: userId,
                    details: AuditEventDetails(
                        additionalInfo: [
                            "conversationId": conversation.id!.uuidString,
                            "provider": "openai"
                        ]
                    )
                )

                // Reload conversations
                loadConversations()
            } catch {
                handleError(error, message: "Unable to create new conversation")
            }
        }
    }

    func deleteConversation(_ conversation: Conversation) {
        guard let conversationId = conversation.id else { return }

        do {
            // Delete all messages first
            try messageRepository.deleteMessages(conversationId: conversationId)

            // Delete conversation
            try conversationRepository.deleteConversation(id: conversationId)

            // Log deletion
            auditLogger.log(
                eventType: .conversationDeleted,
                userId: userId,
                details: AuditEventDetails(
                    additionalInfo: [
                        "conversationId": conversationId.uuidString
                    ]
                )
            )

            // Reload conversations
            loadConversations()
        } catch {
            handleError(error, message: "Unable to delete conversation")
        }
    }

    func clearError() {
        showError = false
        errorMessage = nil
    }

    private func handleError(_ error: Error, message: String) {
        errorMessage = message
        showError = true
        print("ConversationListViewModel error: \(error.localizedDescription)")
    }
}

// MARK: - Preview

#Preview {
    let persistence = PersistenceController.preview
    let conversationRepo = CoreDataConversationRepository(context: persistence.container.viewContext)
    let messageRepo = CoreDataMessageRepository(context: persistence.container.viewContext)

    // Create some preview conversations
    let userId = UUID()
    _ = try? conversationRepo.createConversation(userId: userId, provider: .openai, title: "Health Consultation")
    _ = try? conversationRepo.createConversation(userId: userId, provider: .claude, title: "Symptom Check")

    return ConversationListView(
        userId: userId,
        conversationRepository: conversationRepo,
        messageRepository: messageRepo
    )
}
