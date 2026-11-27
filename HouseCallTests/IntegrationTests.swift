//
//  IntegrationTests.swift
//  HouseCallTests
//
//  Integration tests for cross-component functionality
//

import Testing
import CoreData
import Combine
@testable import HouseCall

@Suite("Integration Tests")
@MainActor
struct IntegrationTests {

    // MARK: - Test Infrastructure

    func createTestComponents() -> (
        context: NSManagedObjectContext,
        encryptionManager: EncryptionManager,
        repository: CoreDataUserRepository,
        authService: AuthenticationService,
        auditLogger: AuditLogger,
        client: FakeCoreAPIAuthClient
    ) {
        let container = NSPersistentContainer(name: "HouseCall", managedObjectModel: TestCoreDataModel.shared)
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
        let client = FakeCoreAPIAuthClient()
        let authService = AuthenticationService(
            userRepository: repository,
            keychainManager: KeychainManager.shared,
            biometricAuthManager: BiometricAuthManager.shared,
            auditLogger: auditLogger,
            coreAuthClient: client,
            coreAPITenantId: FakeCoreAPIAuthClient.tenantId
        )

        return (context, encryptionManager, repository, authService, auditLogger, client)
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
            fullName: "New User",
            authMethod: .password
        )
        // createSession() defers its @Published assignment via Task { @MainActor }.
        // Yield once so that task runs before we read isAuthenticated.
        await Task.yield()

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
        await Task.yield()

        #expect(user.email == email)
        #expect(authService.isAuthenticated == true)
        #expect(authService.currentSession != nil)

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
            fullName: "Session Test",
            authMethod: .password
        )

        let user = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )
        await Task.yield()

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
            fullName: "Logout Test",
            authMethod: .password
        )

        _ = try await authService.login(
            email: email,
            credential: password,
            authMethod: .password
        )
        await Task.yield()

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
            fullName: "Failed Login Test",
            authMethod: .password
        )

        // Core API unreachable -> offline fallback runs the local credential
        // check, which records the failure in the audit log.
        components.client.loginOffline = true

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
            fullName: "Journey User",
            authMethod: .password
        )
        await Task.yield()

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
        await Task.yield()

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

        // Each task hops to the main actor before touching the repository: the
        // repository's `viewContext` is bound to the main queue and Core Data
        // contexts are not thread-safe, so concurrent tasks sharing one context
        // must serialise their access on that context's actor. (Hammering the
        // single context off-actor corrupts in-flight objects — it only passed
        // by timing luck on newer OS versions.)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<5 {
                group.addTask { @MainActor in
                    do {
                        _ = try repository.createUser(
                            email: "concurrent\(i)@example.com",
                            password: "ConcurrentPassword123!",
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
            fullName: "Audit Complete",
            authMethod: .password
        )
        await Task.yield()

        try await authService.logout()

        // Offline fallback performs the local credential check that audits login_success.
        components.client.loginOffline = true
        _ = try await authService.login(
            email: "auditcomplete@example.com",
            credential: "AuditPassword123!",
            authMethod: .password
        )
        await Task.yield()

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
@MainActor
struct AIChatIntegrationTests {

    // MARK: - Test Infrastructure

    @MainActor
    func createChatTestComponents() -> (
        context: NSManagedObjectContext,
        conversationRepo: CoreDataConversationRepository,
        messageRepo: CoreDataMessageRepository,
        userRepo: CoreDataUserRepository,
        aiService: AIConversationService,
        userId: UUID
    ) {
        let container = NSPersistentContainer(name: "HouseCall", managedObjectModel: TestCoreDataModel.shared)
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

        // Create test user
        let user = try! userRepo.createUser(
            email: "chattest@example.com",
            password: "ChatPassword123!",
            fullName: "Chat Test User",
            authMethod: .password
        )

        // Offline coordinator: the cloud send path runs end to end without any
        // live network (every request fails with notConnectedToInternet).
        let keychain = AIChatTestKeychain()
        try? keychain.set(key: KeychainManager.Keys.coreAPIJWT, value: "test.jwt.token")
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [SyncOfflineURLProtocol.self]
        let syncClient = try! SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: URLSession(configuration: sessionConfig),
            keychainManager: keychain
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: auditLogger,
            context: context
        )

        let aiService = AIConversationService(
            userId: user.id!,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            auditLogger: auditLogger,
            syncCoordinator: coordinator
        )

        return (context, conversationRepo, messageRepo, userRepo, aiService, user.id!)
    }

    // MARK: - End-to-End Message Flow Tests

    @Test("Complete message flow: create conversation → send message → persisted as pending")
    @MainActor
    func testCompleteMessageFlow() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let userId = components.userId
        let messageRepo = components.messageRepo

        let conversation = try await aiService.createConversation(
            provider: .openai
        )

        #expect(conversation.userId == userId)
        #expect(conversation.llmProvider == "openai")

        // Cloud is unreachable, so the message stays pending locally; the AI
        // reply only ever arrives via WebSocket.
        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: "I have a headache"
        )

        let messages = try messageRepo.fetchAllMessages(conversationId: conversation.id!)
        let userMessages = messages.filter { $0.role == "user" }
        let assistantMessages = messages.filter { $0.role == "assistant" }

        #expect(userMessages.count == 1)
        #expect(assistantMessages.isEmpty)
        #expect(userMessages[0].syncState == "pending")

        let decryptedUserContent = try messageRepo.decryptMessageContent(userMessages[0])
        #expect(decryptedUserContent.contains("headache"))
    }

    @Test("Offline conversation access")
    @MainActor
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
    @MainActor
    func testMultipleConversations() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let conversationRepo = components.conversationRepo
        let userId = components.userId

        // Create multiple conversations
        let conversation1 = try await aiService.createConversation(
            provider: .openai
        )

        let conversation2 = try await aiService.createConversation(
            provider: .claude
        )

        let conversation3 = try await aiService.createConversation(
            provider: .custom
        )

        // Send messages to each
        try await aiService.sendMessage(conversationId: conversation1.id!, content: "Message 1")
        try await aiService.sendMessage(conversationId: conversation2.id!, content: "Message 2")
        try await aiService.sendMessage(conversationId: conversation3.id!, content: "Message 3")

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
    @MainActor
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
                role: (i % 2 == 0) ? .user : .assistant,
                content: "Message \(i)",
                streamingComplete: true
            )
        }

        // Test pagination
        let firstPage = try messageRepo.fetchMessages(
            conversationId: conversation.id!,
            limit: 20,
            offset: 0
        )
        #expect(firstPage.count == 20)

        let secondPage = try messageRepo.fetchMessages(
            conversationId: conversation.id!,
            limit: 20,
            offset: 20
        )
        #expect(secondPage.count == 20)

        // Verify different messages
        #expect(firstPage[0].id != secondPage[0].id)
    }

    @Test("Conversation deletion cascades to messages")
    @MainActor
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
        // Capture the ID before deletion — accessing the managed object after
        // context.save() + delete may return nil as Core Data clears the fault.
        let conversationId = conversation.id!

        for i in 0..<5 {
            _ = try messageRepo.createMessage(
                conversationId: conversationId,
                role: .user,
                content: "Message \(i)",
                streamingComplete: true
            )
        }

        let messagesBefore = try messageRepo.fetchAllMessages(conversationId: conversationId)
        #expect(messagesBefore.count == 5)

        // Delete conversation (cascade rule in the model deletes related messages)
        try conversationRepo.deleteConversation(id: conversationId)

        // Verify messages are also deleted
        let messagesAfter = try messageRepo.fetchAllMessages(conversationId: conversationId)
        #expect(messagesAfter.isEmpty)
    }

    @Test("Audit logging for all AI interactions")
    @MainActor
    func testAIInteractionAuditLogging() async throws {
        let components = createChatTestComponents()
        let aiService = components.aiService
        let userId = components.userId
        let auditLogger = AuditLogger(context: components.context)

        // Create conversation
        let conversation = try await aiService.createConversation(
            provider: .openai
        )

        // Send message
        try await aiService.sendMessage(
            conversationId: conversation.id!,
            content: "Test message"
        )

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

    @Test("Signed-out send surfaces sign-in error and sends nothing")
    @MainActor
    func testSignedOutSendRequiresSignIn() async throws {
        let components = createChatTestComponents()
        let signedOut = AIConversationService(
            userId: components.userId,
            conversationRepository: components.conversationRepo,
            messageRepository: components.messageRepo,
            auditLogger: AuditLogger(context: components.context)
        )

        let conversation = try await signedOut.createConversation(provider: .openai)

        await #expect(throws: AIConversationError.signInRequired) {
            try await signedOut.sendMessage(
                conversationId: conversation.id!,
                content: "This must not leave the device"
            )
        }

        #expect(signedOut.errorMessage != nil)
        let stored = try components.messageRepo.fetchAllMessages(conversationId: conversation.id!)
        #expect(stored.isEmpty)
    }
}

// MARK: - In-memory Keychain

private final class AIChatTestKeychain: KeychainManager {
    private var store: [String: String] = [:]
    override func set(key: String, value: String) throws { store[key] = value }
    override func get(key: String) throws -> String? { store[key] }
    override func delete(key: String) throws { store.removeValue(forKey: key) }
}

// MARK: - XCTest Compatibility

import XCTest

extension XCTestExpectation {
    convenience init(description: String) {
        self.init()
    }
}
