//
//  MessageRepositoryTests.swift
//  HouseCallTests
//
//  Unit tests for Message Repository
//

import Testing
import CoreData
@testable import HouseCall

@Suite("MessageRepository Tests")
struct MessageRepositoryTests {

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

    /// Helper to create a test conversation
    func createTestConversation(context: NSManagedObjectContext, userId: UUID) throws -> Conversation {
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        return try conversationRepo.createConversation(
            userId: userId,
            provider: .openai,
            title: "Test Conversation"
        )
    }

    // MARK: - Create Message Tests

    @Test("Create user message")
    func testCreateUserMessage() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let message = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "I have a headache",
            streamingComplete: true
        )

        #expect(message.id != nil)
        #expect(message.conversationId == conversation.id)
        #expect(message.role == "user")
        #expect(message.streamingComplete == true)
        #expect(message.encryptedContent != nil)
        #expect(message.timestamp != nil)
    }

    @Test("Create assistant message")
    func testCreateAssistantMessage() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let message = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .assistant,
            content: "I understand you're experiencing a headache",
            streamingComplete: false
        )

        #expect(message.role == "assistant")
        #expect(message.streamingComplete == false)
    }

    @Test("Create system message")
    func testCreateSystemMessage() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let message = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .system,
            content: "You are a medical AI assistant",
            streamingComplete: true
        )

        #expect(message.role == "system")
    }

    // MARK: - Fetch Message Tests

    @Test("Fetch all messages for conversation")
    func testFetchAllMessages() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        _ = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "Message 1",
            streamingComplete: true
        )
        _ = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .assistant,
            content: "Message 2",
            streamingComplete: true
        )
        _ = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "Message 3",
            streamingComplete: true
        )

        let messages = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(messages.count == 3)

        // Messages should be sorted by timestamp ascending
        #expect(messages[0].role == "user")
        #expect(messages[1].role == "assistant")
        #expect(messages[2].role == "user")
    }

    @Test("Fetch messages with pagination")
    func testFetchMessagesWithPagination() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        // Create 10 messages
        for i in 1...10 {
            _ = try messageRepo.createMessage(
                conversationId: conversation.id!,
                role: .user,
                content: "Message \(i)",
                streamingComplete: true
            )
            Thread.sleep(forTimeInterval: 0.001) // Ensure different timestamps
        }

        // Fetch first 5 messages
        let page1 = try messageRepo.fetchMessages(conversationId: conversation.id!, limit: 5, offset: 0)
        #expect(page1.count == 5)

        // Fetch next 5 messages
        let page2 = try messageRepo.fetchMessages(conversationId: conversation.id!, limit: 5, offset: 5)
        #expect(page2.count == 5)

        // Verify no overlap
        #expect(page1[0].id != page2[0].id)
    }

    @Test("Fetch specific message by ID")
    func testFetchMessageById() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let created = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "Test message",
            streamingComplete: true
        )

        let fetched = try messageRepo.fetchMessage(id: created.id!)
        #expect(fetched != nil)
        #expect(fetched?.id == created.id)
    }

    @Test("Fetch messages from different conversations are isolated")
    func testFetchMessagesIsolation() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conv1 = try createTestConversation(context: context, userId: userId)
        let conv2 = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        _ = try messageRepo.createMessage(conversationId: conv1.id!, role: .user, content: "Conv1 Msg1", streamingComplete: true)
        _ = try messageRepo.createMessage(conversationId: conv1.id!, role: .user, content: "Conv1 Msg2", streamingComplete: true)
        _ = try messageRepo.createMessage(conversationId: conv2.id!, role: .user, content: "Conv2 Msg1", streamingComplete: true)

        let conv1Messages = try messageRepo.fetchAllMessages(conversationId: conv1.id!)
        let conv2Messages = try messageRepo.fetchAllMessages(conversationId: conv2.id!)

        #expect(conv1Messages.count == 2)
        #expect(conv2Messages.count == 1)
    }

    // MARK: - Update Message Tests

    @Test("Update message content during streaming")
    func testUpdateMessageContentStreaming() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let message = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .assistant,
            content: "Based on",
            streamingComplete: false
        )

        // Update with more content (simulating streaming)
        try messageRepo.updateMessageContent(
            id: message.id!,
            content: "Based on your symptoms",
            complete: false,
            tokenCount: nil
        )

        var updated = try messageRepo.fetchMessage(id: message.id!)
        var decrypted = try messageRepo.decryptMessageContent(updated!)
        #expect(decrypted == "Based on your symptoms")
        #expect(updated?.streamingComplete == false)

        // Complete the streaming
        try messageRepo.updateMessageContent(
            id: message.id!,
            content: "Based on your symptoms, I recommend rest",
            complete: true,
            tokenCount: 42
        )

        updated = try messageRepo.fetchMessage(id: message.id!)
        decrypted = try messageRepo.decryptMessageContent(updated!)
        #expect(decrypted == "Based on your symptoms, I recommend rest")
        #expect(updated?.streamingComplete == true)
        #expect(updated?.tokenCount == 42)
    }

    @Test("Update message with token count")
    func testUpdateMessageTokenCount() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let message = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .assistant,
            content: "Response",
            streamingComplete: false
        )

        #expect(message.tokenCount == 0)

        try messageRepo.updateMessageContent(
            id: message.id!,
            content: "Complete response",
            complete: true,
            tokenCount: 123
        )

        let updated = try messageRepo.fetchMessage(id: message.id!)
        #expect(updated?.tokenCount == 123)
    }

    // MARK: - Delete Message Tests

    @Test("Delete single message")
    func testDeleteMessage() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let message = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "Test",
            streamingComplete: true
        )

        var fetched = try messageRepo.fetchMessage(id: message.id!)
        #expect(fetched != nil)

        try messageRepo.deleteMessage(id: message.id!)

        fetched = try messageRepo.fetchMessage(id: message.id!)
        #expect(fetched == nil)
    }

    @Test("Delete all messages in conversation")
    func testDeleteAllMessages() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        _ = try messageRepo.createMessage(conversationId: conversation.id!, role: .user, content: "Msg1", streamingComplete: true)
        _ = try messageRepo.createMessage(conversationId: conversation.id!, role: .assistant, content: "Msg2", streamingComplete: true)
        _ = try messageRepo.createMessage(conversationId: conversation.id!, role: .user, content: "Msg3", streamingComplete: true)

        var messages = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(messages.count == 3)

        try messageRepo.deleteMessages(conversationId: conversation.id!)

        messages = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(messages.count == 0)
    }

    // MARK: - Encryption/Decryption Tests

    @Test("Message content is encrypted")
    func testMessageContentEncryption() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let content = "I have chest pain and shortness of breath"
        let message = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: content,
            streamingComplete: true
        )

        // Encrypted content should not equal plaintext
        let encryptedString = String(data: message.encryptedContent!, encoding: .utf8) ?? ""
        #expect(encryptedString != content)

        // But decryption should return original content
        let decrypted = try messageRepo.decryptMessageContent(message)
        #expect(decrypted == content)
    }

    @Test("Message encryption is user-specific")
    func testMessageEncryptionUserSpecific() throws {
        let context = createInMemoryContext()
        let user1 = UUID()
        let user2 = UUID()
        let conv1 = try createTestConversation(context: context, userId: user1)
        let conv2 = try createTestConversation(context: context, userId: user2)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let content = "Same message content"
        let msg1 = try messageRepo.createMessage(conversationId: conv1.id!, role: .user, content: content, streamingComplete: true)
        let msg2 = try messageRepo.createMessage(conversationId: conv2.id!, role: .user, content: content, streamingComplete: true)

        // Same content but different users should produce different encrypted data
        #expect(msg1.encryptedContent != msg2.encryptedContent)

        // But both should decrypt to the same content
        let decrypted1 = try messageRepo.decryptMessageContent(msg1)
        let decrypted2 = try messageRepo.decryptMessageContent(msg2)
        #expect(decrypted1 == content)
        #expect(decrypted2 == content)
    }

    // MARK: - Helper Method Tests

    @Test("Get user ID for conversation")
    func testGetUserIdForConversation() throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let conversation = try createTestConversation(context: context, userId: userId)

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let fetchedUserId = try messageRepo.getUserId(for: conversation.id!)
        #expect(fetchedUserId == userId)
    }

    @Test("Get user ID for non-existent conversation throws error")
    func testGetUserIdForNonExistentConversation() throws {
        let context = createInMemoryContext()
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let randomId = UUID()
        #expect(throws: MessageRepositoryError.self) {
            _ = try messageRepo.getUserId(for: randomId)
        }
    }
}
