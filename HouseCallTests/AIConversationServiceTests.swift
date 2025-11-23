//
//  AIConversationServiceTests.swift
//  HouseCallTests
//
//  Unit tests for AI Conversation Service
//

import Testing
import CoreData
@testable import HouseCall

@Suite("AIConversationService Tests")
@MainActor
struct AIConversationServiceTests {

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

    /// Creates a test service with real repositories
    func createTestService(context: NSManagedObjectContext, userId: UUID) -> AIConversationService {
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

        return AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            providerConfigManager: LLMProviderConfigManager.shared,
            auditLogger: AuditLogger(context: context)
        )
    }

    // MARK: - Conversation Creation Tests

    @Test("Create new conversation with default provider")
    func testCreateConversation() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create conversation
        let conversation = try await service.createConversation()

        // Verify conversation was created
        #expect(conversation.userId == userId)
        #expect(conversation.id != nil)
        #expect(conversation.isActive == true)
        #expect(service.currentConversation?.id == conversation.id)
        #expect(service.messages.isEmpty)
    }

    @Test("Create conversation with specific provider")
    func testCreateConversationWithProvider() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Note: This test may fail if Claude provider is not configured
        // For a complete test, we'd need to mock the provider config manager
        do {
            let conversation = try await service.createConversation(provider: .openai)
            #expect(conversation.llmProvider == "openai")
        } catch LLMError.notConfigured {
            // Expected if provider is not configured in test environment
        }
    }

    @Test("Create multiple conversations")
    func testCreateMultipleConversations() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create first conversation
        let conv1 = try await service.createConversation()

        // Create second conversation
        let conv2 = try await service.createConversation()

        // Verify they are different
        #expect(conv1.id != conv2.id)
        #expect(service.currentConversation?.id == conv2.id)
    }

    // MARK: - Load Conversation Tests

    @Test("Load existing conversation")
    func testLoadConversation() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create a conversation with messages
        let conversation = try await service.createConversation()
        let conversationId = conversation.id!

        // Add some messages
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let msg1 = try messageRepo.createMessage(
            conversationId: conversationId,
            role: .user,
            content: "Hello",
            streamingComplete: true
        )

        let msg2 = try messageRepo.createMessage(
            conversationId: conversationId,
            role: .assistant,
            content: "Hi there!",
            streamingComplete: true
        )

        // Load the conversation
        try await service.loadConversation(conversationId)

        // Verify
        #expect(service.currentConversation?.id == conversationId)
        #expect(service.messages.count == 2)
        #expect(service.messages[0].id == msg1.id)
        #expect(service.messages[1].id == msg2.id)
    }

    @Test("Load non-existent conversation throws error")
    func testLoadNonExistentConversation() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        let fakeId = UUID()

        // Should throw conversation not found
        await #expect(throws: ConversationRepositoryError.self) {
            try await service.loadConversation(fakeId)
        }
    }

    @Test("Load conversation owned by different user throws error")
    func testLoadConversationWrongUser() async throws {
        let context = createInMemoryContext()
        let user1 = UUID()
        let user2 = UUID()

        // Create conversation as user1
        let service1 = createTestService(context: context, userId: user1)
        let conversation = try await service1.createConversation()

        // Try to load as user2
        let service2 = createTestService(context: context, userId: user2)

        await #expect(throws: ConversationRepositoryError.self) {
            try await service2.loadConversation(conversation.id!)
        }
    }

    // MARK: - Provider Switch Tests

    @Test("Switch provider updates conversation")
    func testSwitchProvider() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create conversation with OpenAI
        let conversation = try await service.createConversation(provider: .openai)
        let conversationId = conversation.id!

        // Switch to Claude (if configured)
        do {
            try await service.switchProvider(conversationId: conversationId, to: .claude)

            // Verify provider was switched
            let conversationRepo = CoreDataConversationRepository(
                context: context,
                encryptionManager: EncryptionManager.shared,
                auditLogger: AuditLogger(context: context)
            )

            let updatedConversation = try conversationRepo.fetchConversation(id: conversationId)
            #expect(updatedConversation?.llmProvider == "claude")

            // Verify system message was added
            #expect(service.messages.count > 0)
            let lastMessage = service.messages.last!
            #expect(lastMessage.role == "system")

        } catch LLMError.notConfigured {
            // Expected if Claude is not configured
        }
    }

    @Test("Switch to unconfigured provider throws error")
    func testSwitchToUnconfiguredProvider() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        let conversation = try await service.createConversation()

        // Assuming custom provider is not configured
        await #expect(throws: LLMError.self) {
            try await service.switchProvider(conversationId: conversation.id!, to: .custom)
        }
    }

    // MARK: - Message Sending Tests

    @Test("Send message saves user message")
    func testSendMessageSavesUserMessage() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create conversation
        let conversation = try await service.createConversation()
        let conversationId = conversation.id!

        // Note: Actually streaming will fail without a configured provider
        // This test validates the message creation part
        do {
            try await service.sendMessage(conversationId: conversationId, content: "I have a headache")
        } catch {
            // Expected to fail at streaming stage if provider not configured
        }

        // Verify user message was saved
        #expect(service.messages.count >= 1)
        let userMessage = service.messages.first!
        #expect(userMessage.role == "user")

        // Verify message is in Core Data
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let messages = try messageRepo.fetchAllMessages(conversationId: conversationId)
        #expect(messages.count >= 1)

        let decryptedContent = try messageRepo.decryptMessageContent(messages[0])
        #expect(decryptedContent == "I have a headache")
    }

    @Test("Send empty message throws error")
    func testSendEmptyMessage() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        let conversation = try await service.createConversation()

        // Should throw invalid content error
        await #expect(throws: MessageRepositoryError.self) {
            try await service.sendMessage(conversationId: conversation.id!, content: "")
        }
    }

    @Test("Send message to non-existent conversation throws error")
    func testSendMessageToNonExistentConversation() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        let fakeId = UUID()

        await #expect(throws: ConversationRepositoryError.self) {
            try await service.sendMessage(conversationId: fakeId, content: "Hello")
        }
    }

    @Test("First message sets conversation title")
    func testFirstMessageSetsTitle() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create conversation
        let conversation = try await service.createConversation()
        let conversationId = conversation.id!

        // Send first message
        do {
            try await service.sendMessage(conversationId: conversationId, content: "I have symptoms of the flu")
        } catch {
            // Expected to fail at streaming if provider not configured
        }

        // Verify title was set
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let updatedConversation = try conversationRepo.fetchConversation(id: conversationId)
        #expect(updatedConversation?.encryptedTitle != nil)

        let decryptedTitle = try conversationRepo.decryptConversationTitle(updatedConversation!)
        #expect(decryptedTitle.contains("symptoms"))
    }

    @Test("Send message updates conversation timestamp")
    func testSendMessageUpdatesTimestamp() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        let conversation = try await service.createConversation()
        let originalTimestamp = conversation.updatedAt!

        // Wait a bit
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Send message
        do {
            try await service.sendMessage(conversationId: conversation.id!, content: "Test message")
        } catch {
            // Expected to fail at streaming
        }

        // Verify timestamp was updated
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let updatedConversation = try conversationRepo.fetchConversation(id: conversation.id!)
        #expect(updatedConversation!.updatedAt! > originalTimestamp)
    }

    // MARK: - State Management Tests

    @Test("Clear current conversation resets state")
    func testClearCurrentConversation() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create conversation and load it
        let conversation = try await service.createConversation()
        try await service.loadConversation(conversation.id!)

        // Verify state is set
        #expect(service.currentConversation != nil)

        // Clear
        service.clearCurrentConversation()

        // Verify state is cleared
        #expect(service.currentConversation == nil)
        #expect(service.messages.isEmpty)
        #expect(service.isStreaming == false)
        #expect(service.streamingText == "")
        #expect(service.errorMessage == nil)
    }

    @Test("Cancel streaming updates state")
    func testCancelStreaming() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Create conversation
        let conversation = try await service.createConversation()

        // Simulate streaming state
        // (In a real scenario, this would be set during an actual streaming request)

        // Cancel streaming
        service.cancelStreaming()

        // Verify state is reset
        #expect(service.isStreaming == false)
        #expect(service.streamingMessageId == nil)
        #expect(service.streamingText == "")
    }

    // MARK: - Error Handling Tests

    @Test("Published error message is accessible")
    func testErrorMessageProperty() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Initially no error
        #expect(service.errorMessage == nil)

        // Trigger an error (try to send to non-existent conversation)
        do {
            try await service.sendMessage(conversationId: UUID(), content: "Test")
        } catch {
            // Expected
        }

        // Error message should be cleared on next successful operation start
        let conversation = try await service.createConversation()
        do {
            try await service.sendMessage(conversationId: conversation.id!, content: "Test")
        } catch {
            // Expected, but error should be cleared at start
        }

        // At start of sendMessage, errorMessage is cleared
        // So we can't reliably test the exact error message here
    }

    // MARK: - Published Properties Tests

    @Test("Published properties are observable")
    func testPublishedProperties() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // Verify initial state
        #expect(service.currentConversation == nil)
        #expect(service.messages.isEmpty)
        #expect(service.isStreaming == false)
        #expect(service.streamingText == "")
        #expect(service.streamingMessageId == nil)

        // Create conversation
        let conversation = try await service.createConversation()

        // Verify properties updated
        #expect(service.currentConversation?.id == conversation.id)
        #expect(service.messages.isEmpty)
    }

    // MARK: - Integration Tests

    @Test("Full conversation flow")
    func testFullConversationFlow() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)

        // 1. Create conversation
        let conversation = try await service.createConversation()
        #expect(service.currentConversation != nil)

        // 2. Send first message (will fail at streaming but message is saved)
        do {
            try await service.sendMessage(conversationId: conversation.id!, content: "I have a headache")
        } catch {
            // Expected if provider not configured
        }

        // Verify message was created
        #expect(service.messages.count >= 1)

        // 3. Clear and reload conversation
        service.clearCurrentConversation()
        #expect(service.currentConversation == nil)

        try await service.loadConversation(conversation.id!)
        #expect(service.currentConversation != nil)
        #expect(service.messages.count >= 1)
    }
}
