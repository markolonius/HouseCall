//
//  AIConversationServiceTests.swift
//  HouseCallTests
//
//  Unit tests for AI Conversation Service
//

import Testing
import CoreData
import Combine
import CryptoKit
@testable import HouseCall

@Suite("AIConversationService Tests")
@MainActor
struct AIConversationServiceTests {

    // MARK: - Test Infrastructure

    /// Creates an in-memory Core Data stack for testing
    func createInMemoryContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "HouseCall", managedObjectModel: TestCoreDataModel.shared)
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

    /// Creates a signed-out test service (no sync coordinator) with real repositories.
    func createTestService(context: NSManagedObjectContext, userId: UUID) -> AIConversationService {
        makeService(context: context, userId: userId, withCoordinator: false)
    }

    /// Creates a service wired to a CloudSyncCoordinator whose network is always
    /// offline, so the send path runs end to end without touching the network.
    func createCloudTestService(context: NSManagedObjectContext, userId: UUID) throws -> AIConversationService {
        let service = makeService(context: context, userId: userId, withCoordinator: true)
        return service
    }

    private func makeService(context: NSManagedObjectContext, userId: UUID, withCoordinator: Bool) -> AIConversationService {
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
        var coordinator: CloudSyncCoordinator?
        if withCoordinator {
            let keychain = TestInMemoryKeychain()
            try? keychain.set(key: KeychainManager.Keys.coreAPIJWT, value: "test.jwt.token")
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SyncOfflineURLProtocol.self]
            if let syncClient = try? SyncClient(
                baseURL: URL(string: "http://localhost:8080")!,
                session: URLSession(configuration: config),
                keychainManager: keychain
            ) {
                coordinator = CloudSyncCoordinator(
                    syncClient: syncClient,
                    messageRepository: messageRepo,
                    conversationRepository: conversationRepo,
                    auditLogger: AuditLogger(context: context),
                    context: context
                )
            }
        }
        return AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            auditLogger: AuditLogger(context: context),
            syncCoordinator: coordinator
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

        let conversation = try await service.createConversation(provider: .openai)
        #expect(conversation.llmProvider == "openai")
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

    // MARK: - Message Sending Tests

    @Test("Send message saves user message")
    func testSendMessageSavesUserMessage() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = try createCloudTestService(context: context, userId: userId)

        // Create conversation
        let conversation = try await service.createConversation()
        let conversationId = conversation.id!

        // The coordinator is offline, so the POST cannot complete; the message
        // must still be persisted locally as pending.
        try await service.sendMessage(conversationId: conversationId, content: "I have a headache")

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

    @Test("Send without a sync coordinator throws sign-in required and persists nothing")
    func testSendMessageWithoutCoordinatorRequiresSignIn() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = createTestService(context: context, userId: userId)
        #expect(service.syncCoordinator == nil)

        let conversation = try await service.createConversation()
        let conversationId = conversation.id!

        await #expect(throws: AIConversationError.signInRequired) {
            try await service.sendMessage(conversationId: conversationId, content: "I have a headache")
        }

        // Surfaced to the UI with a PHI-free, patient-facing message.
        #expect(service.errorMessage == AIConversationError.signInRequired.errorDescription)
        #expect(service.errorMessage?.lowercased().contains("sign in") == true)

        // Nothing was persisted, queued, or streamed: no network dependency exists
        // in this configuration and no message left the device.
        #expect(service.messages.isEmpty)
        #expect(service.isStreaming == false)
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        #expect(try messageRepo.fetchAllMessages(conversationId: conversationId).isEmpty)
    }

    @Test("First message sets conversation title")
    func testFirstMessageSetsTitle() async throws {
        let context = createInMemoryContext()
        let userId = UUID()
        let service = try createCloudTestService(context: context, userId: userId)

        // Create conversation
        let conversation = try await service.createConversation()
        let conversationId = conversation.id!

        // Send first message
        try await service.sendMessage(conversationId: conversationId, content: "I have symptoms of the flu")

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
        let service = try createCloudTestService(context: context, userId: userId)

        let conversation = try await service.createConversation()
        let originalTimestamp = conversation.updatedAt!

        // Wait a bit
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds

        // Send message
        try await service.sendMessage(conversationId: conversation.id!, content: "Test message")

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
        let service = try createCloudTestService(context: context, userId: userId)

        // 1. Create conversation
        let conversation = try await service.createConversation()
        #expect(service.currentConversation != nil)

        // 2. Send first message (will fail at streaming but message is saved)
        try await service.sendMessage(conversationId: conversation.id!, content: "I have a headache")

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

// MARK: - Test In-Memory Keychain

/// Keychain substitute that stores values in a plain dictionary.
///
/// Used when tests need a `KeychainManager` that never touches the real iOS
/// Keychain, avoiding `-25299` / entitlement errors in bare simulators.
private class TestInMemoryKeychain: KeychainManager {
    private var storage: [String: String] = [:]

    override func set(key: String, value: String) throws {
        storage[key] = value
    }

    override func get(key: String) throws -> String? {
        return storage[key]
    }

    override func delete(key: String) throws {
        storage.removeValue(forKey: key)
    }
}
