//
//  ConversationViewModelTests.swift
//  HouseCallTests
//
//  View-model error handling for the signed-out send path.
//

import Testing
import CoreData
@testable import HouseCall

@Suite("ConversationViewModel Tests")
@MainActor
struct ConversationViewModelTests {

    @Test("Signed-out send shows the sign-in message immediately with no retry affordance")
    func signedOutSendShowsSignInMessage() async throws {
        let container = NSPersistentContainer(name: "HouseCall", managedObjectModel: TestCoreDataModel.shared)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error { fatalError("Failed to load in-memory store: \(error)") }
        }
        let context = container.viewContext
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let userId = UUID()
        let conversation = try conversationRepo.createConversation(userId: userId, title: nil)
        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            auditLogger: AuditLogger(context: context)
        )
        let viewModel = ConversationViewModel(
            userId: userId,
            conversationId: conversation.id!,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            aiService: service
        )

        await viewModel.sendMessage(content: "hello")

        let message = try #require(viewModel.errorMessage)
        #expect(message == AIConversationError.signInRequired.localizedDescription)
        // ChatView only offers Retry for connect/timeout errors.
        #expect(!message.contains("connect") && !message.contains("timeout"))
    }
}
