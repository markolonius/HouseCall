//
//  IntegrationTests.swift
//  HouseCallTests
//
//  Integration tests for cross-component functionality
//

import Testing
import CoreData
@testable import HouseCall

@Suite("Integration Tests")
struct IntegrationTests {

    // MARK: - Test Infrastructure

    func createTestComponents() -> (
        context: NSManagedObjectContext,
        encryptionManager: EncryptionManager,
        repository: CoreDataUserRepository,
        authService: AuthenticationService,
        auditLogger: AuditLogger
    ) {
        let container = NSPersistentContainer(name: "HouseCall")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }

        let context = container.viewContext
        let encryptionManager = EncryptionManager.shared
        let auditLogger = AuditLogger(context: context)
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: encryptionManager,
            passwordHasher: PasswordHasher.shared,
            auditLogger: auditLogger
        )
        let authService = AuthenticationService(
            userRepository: repository,
            keychainManager: KeychainManager.shared,
            biometricAuthManager: BiometricAuthManager.shared,
            auditLogger: auditLogger
        )

        return (context, encryptionManager, repository, authService, auditLogger)
    }

    // MARK: - Full Registration Flow

    @Test("Full registration flow (password auth)")
    @MainActor
    func testFullRegistrationFlowPassword() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let auditLogger = components.auditLogger

        // Register new user
        let user = try await authService.register(
            email: "newuser@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "New User",
            authMethod: .password
        )

        // Verify user created
        #expect(user.email == "newuser@example.com")
        #expect(user.authMethod == "password")
        #expect(user.encryptedPasswordHash != nil)

        // Verify session created
        #expect(authService.isAuthenticated == true)
        #expect(authService.currentSession != nil)

        // Verify audit log
        let auditEvents = try auditLogger.fetchUserEvents(userId: user.id!)
        let accountCreatedEvents = auditEvents.filter {
            $0.entry.eventType == "account_created"
        }
        let sessionCreatedEvents = auditEvents.filter {
            $0.entry.eventType == "session_created"
        }

        #expect(accountCreatedEvents.count >= 1)
        #expect(sessionCreatedEvents.count >= 1)

        // Cleanup
        try await authService.logout()
    }

    @Test("Full registration flow (passcode auth)")
    @MainActor
    func testFullRegistrationFlowPasscode() async throws {
        let components = createTestComponents()
        let authService = components.authService

        // Register with passcode
        let user = try await authService.register(
            email: "passcodeuser@example.com",
            password: nil,
            passcode: "135792",
            fullName: "Passcode User",
            authMethod: .passcode
        )

        #expect(user.authMethod == "passcode")
        #expect(user.encryptedPasscodeHash != nil)
        #expect(authService.isAuthenticated == true)

        try await authService.logout()
    }

    // MARK: - Full Login Flow

    @Test("Full login flow with password")
    @MainActor
    func testFullLoginFlowPassword() async throws {
        let components = createTestComponents()
        let repository = components.repository
        let authService = components.authService

        let email = "logintest@example.com"
        let password = "LoginPassword123!"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Login Test",
            authMethod: .password
        )

        // Login
        let user = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password,
            useBiometric: false
        )

        #expect(user.email == email)
        #expect(authService.isAuthenticated == true)
        #expect(authService.currentSession != nil)

        try await authService.logout()
    }

    @Test("Full login flow with passcode")
    @MainActor
    func testFullLoginFlowPasscode() async throws {
        let components = createTestComponents()
        let repository = components.repository
        let authService = components.authService

        let email = "passcodelogin@example.com"
        let passcode = "246801"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: nil,
            passcode: passcode,
            fullName: "Passcode Login",
            authMethod: .passcode
        )

        // Login
        let user = try await authService.login(
            email: email,
            credential: passcode,
            authMethod: .passcode,
            useBiometric: false
        )

        #expect(user.email == email)
        #expect(authService.isAuthenticated == true)

        try await authService.logout()
    }

    // MARK: - Session Management Integration

    @Test("Session persists across instances")
    @MainActor
    func testSessionPersistence() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let repository = components.repository

        // Create and login user
        let email = "sessiontest@example.com"
        let password = "SessionPassword123!"

        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Session Test",
            authMethod: .password
        )

        let user = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )

        let sessionToken = authService.currentSession?.sessionToken

        // Verify session exists
        #expect(sessionToken != nil)
        #expect(authService.isAuthenticated == true)

        // Validate session
        let validatedUser = authService.validateSession()
        #expect(validatedUser?.id == user.id)

        try await authService.logout()
    }

    @Test("Logout clears all state")
    @MainActor
    func testLogoutClearsState() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let repository = components.repository

        let email = "logouttest@example.com"
        let password = "LogoutPassword123!"

        // Create and login
        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Logout Test",
            authMethod: .password
        )

        _ = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )

        #expect(authService.isAuthenticated == true)

        // Logout
        try await authService.logout()

        // Verify state cleared
        #expect(authService.isAuthenticated == false)
        #expect(authService.currentSession == nil)
        #expect(authService.validateSession() == nil)
    }

    // MARK: - Error Handling Integration

    @Test("Failed login logs audit event")
    @MainActor
    func testFailedLoginLogsAudit() async throws {
        let components = createTestComponents()
        let repository = components.repository
        let authService = components.authService
        let auditLogger = components.auditLogger

        let email = "failedlogin@example.com"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: "CorrectPassword123!",
            passcode: nil,
            fullName: "Failed Login Test",
            authMethod: .password
        )

        // Attempt login with wrong password
        do {
            _ = try await authService.login(
                email: email,
                credential: "WrongPassword123!",
                authMethod: .password
            )
            #expect(Bool(false), "Login should have failed")
        } catch {
            // Expected to fail
        }

        // Check audit log
        let failureEvents = try auditLogger.fetchEvents(eventType: .loginFailure)
        #expect(failureEvents.count >= 1)
    }

    // MARK: - Encryption Integration

    @Test("End-to-end encryption of user data")
    func testEndToEndEncryption() throws {
        let components = createTestComponents()
        let repository = components.repository

        let fullName = "Encrypted User"
        let password = "EncryptedPassword123!"

        // Create user
        let user = try repository.createUser(
            email: "encrypted@example.com",
            password: password,
            passcode: nil,
            fullName: fullName,
            authMethod: .password
        )

        // Verify encrypted fields don't contain plaintext
        if let encryptedName = user.encryptedFullName {
            let encryptedString = String(data: encryptedName, encoding: .utf8) ?? ""
            #expect(!encryptedString.contains(fullName))
        }

        if let encryptedHash = user.encryptedPasswordHash {
            let hashString = String(data: encryptedHash, encoding: .utf8) ?? ""
            #expect(!hashString.contains(password))
        }

        // Verify decryption works
        let decryptedName = try repository.getDecryptedFullName(for: user)
        #expect(decryptedName == fullName)

        // Verify authentication works (password verification)
        let authenticatedUser = try repository.authenticateUser(
            email: "encrypted@example.com",
            credential: password,
            authMethod: .password
        )
        #expect(authenticatedUser.id == user.id)
    }

    // MARK: - Multi-Component Integration

    @Test("Complete user journey: register → login → logout")
    @MainActor
    func testCompleteUserJourney() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let auditLogger = components.auditLogger

        let email = "journey@example.com"
        let password = "JourneyPassword123!"

        // 1. Register
        let registeredUser = try await authService.register(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Journey User",
            authMethod: .password
        )

        #expect(authService.isAuthenticated == true)

        // 2. Logout
        try await authService.logout()
        #expect(authService.isAuthenticated == false)

        // 3. Login again
        let loggedInUser = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )

        #expect(loggedInUser.id == registeredUser.id)
        #expect(authService.isAuthenticated == true)

        // 4. Verify audit trail
        let auditEvents = try auditLogger.fetchUserEvents(userId: registeredUser.id!)
        #expect(auditEvents.count >= 4) // account_created, session_created, logout, login

        // 5. Final logout
        try await authService.logout()
    }

    // MARK: - Concurrent Operations

    @Test("Concurrent user registrations")
    @MainActor
    func testConcurrentRegistrations() async throws {
        let components = createTestComponents()
        let repository = components.repository

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask {
                    do {
                        _ = try repository.createUser(
                            email: "concurrent\(i)@example.com",
                            password: "ConcurrentPassword123!",
                            passcode: nil,
                            fullName: "Concurrent User \(i)",
                            authMethod: .password
                        )
                    } catch {
                        print("Concurrent registration error: \(error)")
                    }
                }
            }
        }

        // Verify all users created
        for i in 0..<5 {
            let user = repository.findUser(by: "concurrent\(i)@example.com")
            #expect(user != nil)
        }
    }

    // MARK: - Data Integrity

    @Test("Audit log completeness")
    @MainActor
    func testAuditLogCompleteness() async throws {
        let components = createTestComponents()
        let authService = components.authService
        let auditLogger = components.auditLogger

        // Perform multiple operations
        let user = try await authService.register(
            email: "auditcomplete@example.com",
            password: "AuditPassword123!",
            passcode: nil,
            fullName: "Audit Complete",
            authMethod: .password
        )

        try await authService.logout()

        _ = try await authService.login(
            email: "auditcomplete@example.com",
            credential: "AuditPassword123!",
            authMethod: .password
        )

        try await authService.logout()

        // Verify all events logged
        let allEvents = try auditLogger.fetchUserEvents(userId: user.id!)

        let hasAccountCreated = allEvents.contains { $0.entry.eventType == "account_created" }
        let hasLoginSuccess = allEvents.contains { $0.entry.eventType == "login_success" }
        let hasLogout = allEvents.contains { $0.entry.eventType == "logout_success" }

        #expect(hasAccountCreated)
        #expect(hasLoginSuccess)
        #expect(hasLogout)
    }
}

// MARK: - AI Chat Integration Tests

@Suite("AI Chat Integration Tests")
struct AIChatIntegrationTests {

    // MARK: - Test Infrastructure

    func createChatTestComponents() -> (
        context: NSManagedObjectContext,
        conversationRepo: CoreDataConversationRepository,
        messageRepo: CoreDataMessageRepository,
        userRepo: CoreDataUserRepository,
        aiService: AIConversationService,
        userId: UUID
    ) {
        let container = NSPersistentContainer(name: "HouseCall")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }

        let context = container.viewContext
        let encryptionManager = EncryptionManager.shared
        let auditLogger = AuditLogger(context: context)

        let userRepo = CoreDataUserRepository(
            context: context,
            encryptionManager: encryptionManager,
            passwordHasher: PasswordHasher.shared,
            auditLogger: auditLogger
        )

        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: encryptionManager,
            auditLogger: auditLogger
        )

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: encryptionManager,
            auditLogger: auditLogger
        )

        // Create mock LLM providers
        let openAIProvider = MockLLMProvider(type: .openai)
        let claudeProvider = MockLLMProvider(type: .claude)
        let customProvider = MockLLMProvider(type: .custom)

        let aiService = AIConversationService(
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            openAIProvider: openAIProvider,
            claudeProvider: claudeProvider,
            customProvider: customProvider,
            auditLogger: auditLogger
        )

        // Create test user
        let user = try! userRepo.createUser(
            email: "chattest@example.com",
            password: "ChatPassword123!",
            passcode: nil,
            fullName: "Chat Test User",
            authMethod: .password
        )

        return (context, conversationRepo, messageRepo, userRepo, aiService, user.id!)
    }

    // MARK: - End-to-End Message Flow Tests

    @Test("Complete message flow: create conversation → send message → receive response")
    func testCompleteMessageFlow() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let userId = components.userId
        let messageRepo = components.messageRepo

        // 1. Create conversation
        let conversation = try await aiService.createConversation(
            userId: userId,
            provider: .openai,
            title: "Test Conversation"
        )

        #expect(conversation.userId == userId)
        #expect(conversation.llmProvider == "openai")

        // 2. Send user message
        let userMessage = "I have a headache"
        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: userMessage,
            userId: userId
        )

        // 3. Wait for AI response to complete
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second

        // 4. Fetch all messages
        let messages = try messageRepo.fetchAllMessages(conversationId: conversation.id!)

        // Verify message structure
        #expect(messages.count >= 2) // User message + AI response
        let userMessages = messages.filter { $0.role == "user" }
        let assistantMessages = messages.filter { $0.role == "assistant" }

        #expect(userMessages.count >= 1)
        #expect(assistantMessages.count >= 1)

        // Verify user message content
        let decryptedUserContent = try messageRepo.decryptMessageContent(userMessages[0])
        #expect(decryptedUserContent.contains("headache"))

        // Verify AI response exists
        #expect(assistantMessages[0].streamingComplete == true)
    }

    @Test("Provider switching maintains conversation context")
    func testProviderSwitching() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let userId = components.userId
        let conversationRepo = components.conversationRepo

        // Create conversation with OpenAI
        let conversation = try await aiService.createConversation(
            userId: userId,
            provider: .openai,
            title: "Provider Switch Test"
        )

        #expect(conversation.llmProvider == "openai")

        // Send first message
        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: "First message",
            userId: userId
        )

        // Switch to Claude
        try await aiService.switchProvider(
            conversationId: conversation.id!,
            to: .claude,
            userId: userId
        )

        // Verify provider switched
        let updatedConversation = try conversationRepo.fetchConversation(id: conversation.id!)
        #expect(updatedConversation?.llmProvider == "claude")

        // Send second message with new provider
        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: "Second message",
            userId: userId
        )

        // Both messages should be in the conversation
        let messages = try components.messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(messages.count >= 4) // 2 user messages + 2 AI responses
    }

    @Test("Streaming message updates work correctly")
    func testStreamingMessageUpdates() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let userId = components.userId

        let conversation = try await aiService.createConversation(
            userId: userId,
            provider: .openai,
            title: "Streaming Test"
        )

        var chunkCount = 0
        let expectation = XCTestExpectation(description: "Streaming chunks received")

        // Monitor streaming updates
        let cancellable = aiService.$streamingText
            .sink { text in
                if !text.isEmpty {
                    chunkCount += 1
                }
            }

        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: "Tell me about symptoms",
            userId: userId
        )

        // Wait for streaming to complete
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds

        // Verify chunks were received
        #expect(chunkCount > 0)
        #expect(aiService.isStreaming == false)

        cancellable.cancel()
    }

    @Test("Offline conversation access")
    func testOfflineConversationAccess() throws {
        let components = createChatTestComponents()
        let conversationRepo = components.conversationRepo
        let messageRepo = components.messageRepo
        let userId = components.userId

        // Create conversation and messages offline (no AI service)
        let conversation = try conversationRepo.createConversation(
            userId: userId,
            provider: .openai,
            title: "Offline Conversation"
        )

        _ = try messageRepo.createMessage(
            conversationId: conversation.id!,
            userId: userId,
            role: .user,
            content: "Stored message",
            streamingComplete: true
        )

        // Verify we can fetch offline
        let fetchedConversation = try conversationRepo.fetchConversation(id: conversation.id!)
        #expect(fetchedConversation != nil)

        let messages = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(messages.count == 1)

        let decryptedContent = try messageRepo.decryptMessageContent(messages[0])
        #expect(decryptedContent == "Stored message")
    }

    @Test("Multiple conversations per user")
    func testMultipleConversations() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let conversationRepo = components.conversationRepo
        let userId = components.userId

        // Create multiple conversations
        let conversation1 = try await aiService.createConversation(
            userId: userId,
            provider: .openai,
            title: "First Conversation"
        )

        let conversation2 = try await aiService.createConversation(
            userId: userId,
            provider: .claude,
            title: "Second Conversation"
        )

        let conversation3 = try await aiService.createConversation(
            userId: userId,
            provider: .custom,
            title: "Third Conversation"
        )

        // Send messages to each
        try await aiService.sendMessage(conversationId: conversation1.id!, content: "Message 1", userId: userId)
        try await aiService.sendMessage(conversationId: conversation2.id!, content: "Message 2", userId: userId)
        try await aiService.sendMessage(conversationId: conversation3.id!, content: "Message 3", userId: userId)

        // Verify all conversations exist
        let conversations = try conversationRepo.fetchConversations(userId: userId)
        #expect(conversations.count >= 3)

        // Verify different providers
        let providers = Set(conversations.map { $0.llmProvider })
        #expect(providers.contains("openai"))
        #expect(providers.contains("claude"))
        #expect(providers.contains("custom"))
    }

    @Test("Message pagination works correctly")
    func testMessagePagination() throws {
        let components = createChatTestComponents()
        let conversationRepo = components.conversationRepo
        let messageRepo = components.messageRepo
        let userId = components.userId

        // Create conversation with many messages
        let conversation = try conversationRepo.createConversation(
            userId: userId,
            provider: .openai,
            title: "Pagination Test"
        )

        // Create 100 messages
        for i in 0..<100 {
            _ = try messageRepo.createMessage(
                conversationId: conversation.id!,
                userId: userId,
                role: (i % 2 == 0) ? .user : .assistant,
                content: "Message \(i)",
                streamingComplete: true
            )
        }

        // Test pagination
        let firstPage = try messageRepo.fetchMessages(
            conversationId: conversation.id!,
            userId: userId,
            limit: 20,
            offset: 0
        )
        #expect(firstPage.count == 20)

        let secondPage = try messageRepo.fetchMessages(
            conversationId: conversation.id!,
            userId: userId,
            limit: 20,
            offset: 20
        )
        #expect(secondPage.count == 20)

        // Verify different messages
        #expect(firstPage[0].id != secondPage[0].id)
    }

    @Test("Conversation deletion cascades to messages")
    func testConversationDeletionCascade() throws {
        let components = createChatTestComponents()
        let conversationRepo = components.conversationRepo
        let messageRepo = components.messageRepo
        let userId = components.userId

        // Create conversation with messages
        let conversation = try conversationRepo.createConversation(
            userId: userId,
            provider: .openai,
            title: "Delete Test"
        )

        for i in 0..<5 {
            _ = try messageRepo.createMessage(
                conversationId: conversation.id!,
                userId: userId,
                role: .user,
                content: "Message \(i)",
                streamingComplete: true
            )
        }

        let messagesBefore = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(messagesBefore.count == 5)

        // Delete conversation
        try conversationRepo.deleteConversation(id: conversation.id!)

        // Verify messages are also deleted
        let messagesAfter = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(messagesAfter.isEmpty)
    }

    @Test("Audit logging for all AI interactions")
    func testAIInteractionAuditLogging() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let userId = components.userId
        let auditLogger = AuditLogger(context: components.context)

        // Create conversation
        let conversation = try await aiService.createConversation(
            userId: userId,
            provider: .openai,
            title: "Audit Test"
        )

        // Send message
        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: "Test message",
            userId: userId
        )

        // Wait for completion
        try await Task.sleep(nanoseconds: 100_000_000)

        // Verify audit events
        let events = try auditLogger.fetchUserEvents(userId: userId)

        let conversationEvents = events.filter {
            $0.entry.eventType == "conversation_created"
        }

        let messageEvents = events.filter {
            $0.entry.eventType == "message_created"
        }

        #expect(conversationEvents.count >= 1)
        #expect(messageEvents.count >= 1)
    }

    @Test("Error recovery during streaming")
    func testStreamingErrorRecovery() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let userId = components.userId

        let conversation = try await aiService.createConversation(
            userId: userId,
            provider: .openai,
            title: "Error Recovery Test"
        )

        // Configure mock provider to fail
        if let mockProvider = aiService.openAIProvider as? MockLLMProvider {
            mockProvider.shouldFail = true
        }

        // Attempt to send message (should handle error gracefully)
        do {
            try await aiService.sendMessage(
                conversationId: conversation.id!,
                content: "This should fail",
                userId: userId
            )
        } catch {
            // Error expected
        }

        // Verify service is still functional
        #expect(aiService.errorMessage != nil)
        #expect(aiService.isStreaming == false)

        // Recover and send again
        if let mockProvider = aiService.openAIProvider as? MockLLMProvider {
            mockProvider.shouldFail = false
        }

        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: "This should succeed",
            userId: userId
        )

        // Verify recovery
        #expect(aiService.errorMessage == nil)
    }
}

// MARK: - Mock LLM Provider

private class MockLLMProvider: LLMProvider {
    let providerType: LLMProviderType
    var isConfigured: Bool = true
    var shouldFail: Bool = false

    init(type: LLMProviderType) {
        self.providerType = type
    }

    func streamCompletion(
        messages: [ChatMessage],
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        if shouldFail {
            onComplete(.failure(.networkError(NSError(domain: "test", code: -1))))
            return
        }

        // Simulate streaming chunks
        let response = "This is a mock response from \(providerType.rawValue) provider."
        let chunks = response.split(separator: " ").map(String.init)

        for chunk in chunks {
            onChunk(chunk + " ")
            try await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        }

        onComplete(.success(response))
    }

    func cancelStreaming() {
        // Mock cancellation
    }
}

// MARK: - XCTest Compatibility

import XCTest

extension XCTestExpectation {
    convenience init(description: String) {
        self.init()
    }
}
