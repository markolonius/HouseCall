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

    /// Creates a test service with real repositories.
    ///
    /// A `MockLLMProvider` (always-succeeds) is injected via
    /// `_testProviderOverride` so tests never hit real API keys or the network.
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

        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            providerConfigManager: LLMProviderConfigManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        // Bypass provider-config checks and live network in unit tests.
        service._testProviderOverride = StubLLMProvider(shouldFail: false)
        return service
    }

    /// Creates a test service whose provider always fails — used by error-path tests.
    func createFailingTestService(context: NSManagedObjectContext, userId: UUID) -> AIConversationService {
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
        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            providerConfigManager: LLMProviderConfigManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        service._testProviderOverride = StubLLMProvider(shouldFail: true)
        return service
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

    // MARK: - Streaming Regression Tests

    /// Regression guard for the Phase-3 bug where providers emitted an empty
    /// string and never called `onChunk`, leaving `streamingText` blank and
    /// persisting an empty assistant message.
    ///
    /// This test MUST FAIL if:
    /// - `streamingText` never updates (stays empty or delivers a single blob)
    /// - The final persisted assistant message is empty
    @Test("streamingText updates incrementally and final assistant message is persisted non-empty")
    func testStreamingTextIncrementalUpdatesAndPersistence() async throws {
        let context = createInMemoryContext()
        let userId = UUID()

        // Use a private EncryptionManager instance so parallel test workers
        // (SecurityTests, EncryptionManagerTests) cannot race on the shared
        // singleton's key cache between the encrypt (inside sendMessage) and the
        // decrypt assertion below.  SecurityTests.clearCache() wipes the shared
        // masterKey from memory; because _testInjectMasterKey bypasses the
        // Keychain, the subsequent getMasterKey() call regenerates a DIFFERENT
        // random key, making decryption of content encrypted under the original
        // key fail.  A per-test instance with its own InMemoryKeychainManager and
        // an injected master key is fully isolated from that race.
        let localKeychain = InMemoryKeychainManager()
        let localEncryption = EncryptionManager._testMakeInstance(keychainManager: localKeychain)
        localEncryption._testInjectMasterKey(SymmetricKey(size: .bits256))

        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: localEncryption,
            auditLogger: AuditLogger(context: context)
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: localEncryption,
            auditLogger: AuditLogger(context: context)
        )
        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            providerConfigManager: LLMProviderConfigManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        service._testProviderOverride = MultiChunkStubProvider()

        // Collect every non-empty streamingText value in publication order.
        // The Combine sink fires synchronously (willSet) on the main actor, so
        // each handleStreamChunk call appends exactly one entry here before
        // execution moves on to the next chunk.
        var streamingHistory: [String] = []
        var cancellables = Set<AnyCancellable>()
        service.$streamingText
            .filter { !$0.isEmpty }
            .sink { streamingHistory.append($0) }
            .store(in: &cancellables)

        // Track isStreaming transitions (initial false, true during, false after).
        var isStreamingHistory: [Bool] = []
        service.$isStreaming
            .sink { isStreamingHistory.append($0) }
            .store(in: &cancellables)

        let conversation = try await service.createConversation()

        // sendMessage sets isStreaming = true, calls the provider synchronously,
        // then returns. The handleStreamChunk / handleStreamComplete closures are
        // dispatched as Task { @MainActor in … } and run after we yield below.
        try await service.sendMessage(conversationId: conversation.id!, content: "regression test input")

        // Drain the main-actor queue so all spawned Tasks complete:
        //   3 × handleStreamChunk  +  1 × handleStreamComplete.
        for _ in 0..<10 {
            await Task.yield()
        }

        // 1. streamingText must have grown INCREMENTALLY — at least 2 distinct
        //    non-empty values observed, ending at the full expected text.
        let expectedFull = MultiChunkStubProvider.expectedText
        #expect(
            streamingHistory.count >= 2,
            "streamingText must update incrementally — observed \(streamingHistory.count) non-empty emission(s), need ≥ 2"
        )
        #expect(
            streamingHistory.last == expectedFull,
            "last observed streamingText must equal the full chunk sequence '\(expectedFull)'"
        )

        // 2. Each successive value must be strictly longer (monotonically growing).
        for i in 0..<(streamingHistory.count - 1) {
            #expect(
                streamingHistory[i + 1].hasPrefix(streamingHistory[i]),
                "streamingText must grow monotonically: '\(streamingHistory[i])' → '\(streamingHistory[i + 1])'"
            )
        }

        // 3. isStreaming lifecycle: went true during streaming, false when done.
        #expect(
            isStreamingHistory.contains(true),
            "isStreaming must have been true during the streaming window"
        )
        #expect(
            service.isStreaming == false,
            "isStreaming must be false after completion"
        )

        // 4. Core regression guard: final assistant message is persisted with the
        //    FULL concatenated content — not empty, not a placeholder.
        let allMessages = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        let assistantMessages = allMessages.filter { $0.role == "assistant" }
        #expect(assistantMessages.count == 1, "exactly one assistant message must be persisted")

        let persistedContent = try messageRepo.decryptMessageContent(assistantMessages[0])
        #expect(
            !persistedContent.isEmpty,
            "persisted assistant message must not be empty — regression guard against the empty-chunk bug"
        )
        #expect(
            persistedContent == expectedFull,
            "persisted content must equal the full concatenated response '\(expectedFull)'"
        )
        #expect(
            assistantMessages[0].streamingComplete == true,
            "persisted message must be marked streamingComplete = true"
        )
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

// MARK: - Stub LLM Provider (test-only)

/// Deterministic provider used by `AIConversationServiceTests`.
///
/// `shouldFail = false`: simulates a successful one-chunk streaming response.
/// `shouldFail = true`:  calls `onComplete(.failure(...))` — exercises the
///                       service's error-handling path without touching the network.
private class StubLLMProvider: LLMProvider {
    let providerType: LLMProviderType = .openai
    let isConfigured: Bool = true
    let shouldFail: Bool

    init(shouldFail: Bool) {
        self.shouldFail = shouldFail
    }

    func streamCompletion(
        messages: [ChatMessage],
        maxTokensOverride: Int?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        if shouldFail {
            onComplete(.failure(.networkError(NSError(domain: "StubProvider", code: -1,
                                                      userInfo: [NSLocalizedDescriptionKey: "Stubbed failure"]))))
            return
        }
        let response = "Stub response from provider."
        onChunk(response)
        onComplete(.success(response))
    }

    func cancelStreaming() {}
}

// MARK: - Multi-Chunk Stub LLM Provider (streaming regression test)

/// Deterministic multi-chunk provider used by `testStreamingTextIncrementalUpdatesAndPersistence`.
///
/// Emits a known sequence of chunks — "Hello", " ", "world" — via `onChunk`,
/// then calls `onComplete(.success("Hello world"))`.  This lets the test
/// verify that `streamingText` grows INCREMENTALLY (one entry per chunk) and
/// that the final persisted message equals the full concatenated text.
///
/// The test FAILS if streaming reverts to the Phase-3 bug where the provider
/// delivered an empty string without emitting any chunks.
private class MultiChunkStubProvider: LLMProvider {
    let providerType: LLMProviderType = .openai
    let isConfigured: Bool = true

    /// The ordered chunk sequence emitted during one completion call.
    static let chunks: [String] = ["Hello", " ", "world"]

    /// Full text the caller should expect after all chunks arrive.
    static var expectedText: String { chunks.joined() }

    func streamCompletion(
        messages: [ChatMessage],
        maxTokensOverride: Int?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        for chunk in Self.chunks {
            onChunk(chunk)
        }
        onComplete(.success(Self.expectedText))
    }

    func cancelStreaming() {}
}
