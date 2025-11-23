//
//  ConversationRepositoryTests.swift
//  HouseCallTests
//
//  Unit tests for Conversation Repository
//

import Testing
import CoreData
@testable import HouseCall

@Suite("ConversationRepository Tests")
struct ConversationRepositoryTests {

    // MARK: - Test Infrastructure

    /// Creates an in-memory Core Data stack for testing
    func createInMemoryContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "HouseCall")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }

        return container.viewContext
    }

    // MARK: - Create Conversation Tests

    @Test("Create conversation with default provider")
    func testCreateConversationDefaultProvider() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let conversation = try repository.createConversation(
            userId: userId,
            provider: .openai,
            title: nil
        )

        #expect(conversation.userId == userId)
        #expect(conversation.llmProvider == "openai")
        #expect(conversation.isActive == true)
        #expect(conversation.id != nil)
        #expect(conversation.createdAt != nil)
        #expect(conversation.updatedAt != nil)
    }

    @Test("Create conversation with encrypted title")
    func testCreateConversationWithTitle() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let title = "Discussion about headaches"
        let conversation = try repository.createConversation(
            userId: userId,
            provider: .claude,
            title: title
        )

        #expect(conversation.encryptedTitle != nil)
        #expect(conversation.encryptedTitle!.count > 0)

        // Verify decryption works
        let decryptedTitle = try repository.decryptConversationTitle(conversation)
        #expect(decryptedTitle == title)
    }

    @Test("Create multiple conversations for same user")
    func testCreateMultipleConversations() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let conv1 = try repository.createConversation(userId: userId, provider: .openai, title: "Conv 1")
        let conv2 = try repository.createConversation(userId: userId, provider: .claude, title: "Conv 2")
        let conv3 = try repository.createConversation(userId: userId, provider: .custom, title: "Conv 3")

        #expect(conv1.id != conv2.id)
        #expect(conv2.id != conv3.id)
        #expect(conv1.userId == userId)
        #expect(conv2.userId == userId)
        #expect(conv3.userId == userId)
    }

    // MARK: - Fetch Conversation Tests

    @Test("Fetch all conversations for user")
    func testFetchConversationsForUser() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let user1 = UUID()
        let user2 = UUID()

        _ = try repository.createConversation(userId: user1, provider: .openai, title: "User1 Conv1")
        _ = try repository.createConversation(userId: user1, provider: .claude, title: "User1 Conv2")
        _ = try repository.createConversation(userId: user2, provider: .openai, title: "User2 Conv1")

        let user1Conversations = try repository.fetchConversations(userId: user1)
        let user2Conversations = try repository.fetchConversations(userId: user2)

        #expect(user1Conversations.count == 2)
        #expect(user2Conversations.count == 1)
    }

    @Test("Fetch conversations sorted by updated time")
    func testFetchConversationsSorted() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let conv1 = try repository.createConversation(userId: userId, provider: .openai, title: "First")
        Thread.sleep(forTimeInterval: 0.01) // Small delay to ensure different timestamps
        let conv2 = try repository.createConversation(userId: userId, provider: .openai, title: "Second")
        Thread.sleep(forTimeInterval: 0.01)
        let conv3 = try repository.createConversation(userId: userId, provider: .openai, title: "Third")

        let conversations = try repository.fetchConversations(userId: userId)

        // Should be sorted by updatedAt descending (newest first)
        #expect(conversations[0].id == conv3.id)
        #expect(conversations[1].id == conv2.id)
        #expect(conversations[2].id == conv1.id)
    }

    @Test("Fetch specific conversation by ID")
    func testFetchConversationById() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let created = try repository.createConversation(userId: userId, provider: .openai, title: "Test")

        let fetched = try repository.fetchConversation(id: created.id!)
        #expect(fetched != nil)
        #expect(fetched?.id == created.id)
        #expect(fetched?.userId == userId)
    }

    @Test("Fetch non-existent conversation returns nil")
    func testFetchNonExistentConversation() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let randomId = UUID()
        let fetched = try repository.fetchConversation(id: randomId)
        #expect(fetched == nil)
    }

    // MARK: - Update Conversation Tests

    @Test("Update conversation title")
    func testUpdateConversationTitle() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let conversation = try repository.createConversation(
            userId: userId,
            provider: .openai,
            title: "Original Title"
        )

        let newTitle = "Updated Title"
        try repository.updateConversationTitle(id: conversation.id!, title: newTitle)

        let updated = try repository.fetchConversation(id: conversation.id!)
        let decryptedTitle = try repository.decryptConversationTitle(updated!)
        #expect(decryptedTitle == newTitle)
    }

    @Test("Update conversation timestamp")
    func testUpdateConversationTimestamp() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let conversation = try repository.createConversation(userId: userId, provider: .openai)
        let originalTimestamp = conversation.updatedAt

        Thread.sleep(forTimeInterval: 0.1)
        let newTimestamp = Date()
        try repository.updateConversationTimestamp(id: conversation.id!, timestamp: newTimestamp)

        let updated = try repository.fetchConversation(id: conversation.id!)
        #expect(updated?.updatedAt != originalTimestamp)
        #expect(updated?.updatedAt == newTimestamp)
    }

    @Test("Update conversation provider")
    func testUpdateConversationProvider() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let conversation = try repository.createConversation(userId: userId, provider: .openai)
        #expect(conversation.llmProvider == "openai")

        try repository.updateConversationProvider(id: conversation.id!, provider: .claude)

        let updated = try repository.fetchConversation(id: conversation.id!)
        #expect(updated?.llmProvider == "claude")
    }

    // MARK: - Delete Conversation Tests

    @Test("Delete conversation")
    func testDeleteConversation() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let userId = UUID()
        let conversation = try repository.createConversation(userId: userId, provider: .openai)
        let conversationId = conversation.id!

        // Verify it exists
        var fetched = try repository.fetchConversation(id: conversationId)
        #expect(fetched != nil)

        // Delete it
        try repository.deleteConversation(id: conversationId)

        // Verify it's gone
        fetched = try repository.fetchConversation(id: conversationId)
        #expect(fetched == nil)
    }

    @Test("Delete non-existent conversation throws error")
    func testDeleteNonExistentConversation() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let randomId = UUID()
        #expect(throws: ConversationRepositoryError.self) {
            try repository.deleteConversation(id: randomId)
        }
    }

    // MARK: - Encryption/Decryption Tests

    @Test("Title encryption is user-specific")
    func testTitleEncryptionUserSpecific() throws {
        let context = createInMemoryContext()
        let repository = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let user1 = UUID()
        let user2 = UUID()
        let title = "Same Title"

        let conv1 = try repository.createConversation(userId: user1, provider: .openai, title: title)
        let conv2 = try repository.createConversation(userId: user2, provider: .openai, title: title)

        // Same title but different users should produce different encrypted data
        #expect(conv1.encryptedTitle != conv2.encryptedTitle)

        // But both should decrypt to the same title
        let decrypted1 = try repository.decryptConversationTitle(conv1)
        let decrypted2 = try repository.decryptConversationTitle(conv2)
        #expect(decrypted1 == title)
        #expect(decrypted2 == title)
    }
}
