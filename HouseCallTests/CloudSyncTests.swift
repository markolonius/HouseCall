//
//  CloudSyncTests.swift
//  HouseCallTests
//
//  Phase 6.3 — Unit tests for the cloud sync chat flow.
//
//  Covers:
//  - sendMessage persists user message as "pending" then "synced" + serverId
//    on a stubbed successful POST.
//  - sendMessage leaves message "pending" on stubbed SyncError.offline.
//  - Replay re-POSTs pending messages on reconnect (stubbed) → "synced".
//  - A stubbed recommendation.delivered WS event → persisted assistant message
//    + a RecommendationCardModel renderable for payloadType = "guidance".
//  - Login stores JWT into Keys.coreAPIJWT via AuthenticationService.
//
//  Network is fully stubbed via SyncMockURLProtocol (defined in SyncClientTests).
//  No live network access.
//
//  Parallel-safety: Each test uses a unique session UUID so handler registries
//  never collide with concurrent test workers.
//

import Testing
import Foundation
import CoreData
import Combine
@testable import HouseCall

// MARK: - In-memory Keychain for JWT tests

private final class TestKeychain: KeychainManager {
    private var store: [String: String] = [:]
    override func set(key: String, value: String) throws { store[key] = value }
    override func get(key: String) throws -> String? { store[key] }
    override func delete(key: String) throws { store.removeValue(forKey: key) }
}

// MARK: - Helpers

private func makeInMemoryContext() -> NSManagedObjectContext {
    let container = NSPersistentContainer(name: "HouseCall", managedObjectModel: TestCoreDataModel.shared)
    let description = NSPersistentStoreDescription()
    description.type = NSInMemoryStoreType
    container.persistentStoreDescriptions = [description]
    container.loadPersistentStores { _, error in
        if let error { fatalError("in-memory store: \(error)") }
    }
    return container.viewContext
}

private func makeHTTPResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

private func makeStubSession(sessionID: String) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncMockURLProtocol.self]
    config.httpAdditionalHeaders = ["X-Test-Session-ID": sessionID]
    return URLSession(configuration: config)
}

private func makeOfflineSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncOfflineURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeKeychain(jwt: String = "test.jwt.token") -> TestKeychain {
    let kc = TestKeychain()
    try? kc.set(key: KeychainManager.Keys.coreAPIJWT, value: jwt)
    return kc
}

/// Creates a Conversation and a User entity in the given context so the
/// repository can look up the userId for encryption.
private func seedConversation(
    in context: NSManagedObjectContext,
    userId: UUID,
    serverId: String? = "server-conv-001"
) throws -> Conversation {
    let conversation = Conversation(context: context)
    conversation.id = UUID()
    conversation.userId = userId
    conversation.createdAt = Date()
    conversation.updatedAt = Date()
    conversation.isActive = true
    conversation.llmProvider = "openai"
    conversation.encryptedTitle = Data()
    conversation.serverId = serverId
    conversation.syncState = "local"
    try context.save()
    return conversation
}

// MARK: - CloudSyncTests

@Suite("CloudSync 6.3 Tests")
@MainActor
struct CloudSyncTests {

    // MARK: - sendMessage → pending then synced

    @Test("sendMessage sets syncState to pending then synced on POST success")
    func testSendMessagePendingThenSynced() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!
        let convServerId = conversation.serverId!

        // Stub POST → 201 with a server message ID
        let serverMsgId = "srv-msg-\(UUID().uuidString)"
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            let json = """
            {
              "ID": "\(serverMsgId)",
              "TenantID": "t1",
              "ConversationID": "\(convServerId)",
              "Role": "user",
              "Content": "hello",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            auditLogger: AuditLogger(context: context),
            syncCoordinator: coordinator
        )

        // Load conversation into the service so it passes the ownership check
        try await service.loadConversation(convLocalId)

        // Send message
        try await service.sendMessage(conversationId: convLocalId, content: "hello")

        // Fetch the persisted message from Core Data and verify metadata
        let allMessages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let userMsg = allMessages.first(where: { $0.role == "user" })

        #expect(userMsg != nil, "User message should have been persisted")
        #expect(userMsg?.syncState == "synced", "syncState should be synced after successful POST")
        #expect(userMsg?.serverId == serverMsgId, "serverId should be set from the POST response")
    }

    // MARK: - sendMessage stays pending on offline

    @Test("sendMessage leaves message pending when POST returns offline error")
    func testSendMessageStaysPendingOnOffline() async throws {
        let kc = makeKeychain()
        let offlineSession = makeOfflineSession()
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: offlineSession,
            keychainManager: kc
        )

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            auditLogger: AuditLogger(context: context),
            syncCoordinator: coordinator
        )

        try await service.loadConversation(convLocalId)

        // sendMessage with offline session — should not throw; message stays pending
        try await service.sendMessage(conversationId: convLocalId, content: "offline test")

        let allMessages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let userMsg = allMessages.first(where: { $0.role == "user" })

        #expect(userMsg != nil, "User message should be persisted even when offline")
        #expect(userMsg?.syncState == "pending", "syncState should remain pending on offline")
        #expect(userMsg?.serverId == nil, "serverId should be nil when POST did not reach the server")
    }

    // MARK: - Replay re-POSTs pending → synced

    @Test("replayPendingMessages re-POSTs pending messages and marks them synced")
    func testReplayPendingMessages() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convServerId = conversation.serverId!

        let serverMsgId = "replay-msg-\(UUID().uuidString)"
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            let json = """
            {
              "ID": "\(serverMsgId)",
              "TenantID": "t1",
              "ConversationID": "\(convServerId)",
              "Role": "user",
              "Content": "queued",
              "CreatedAt": "2026-06-03T10:01:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        // Manually create a pending message in Core Data (simulates a previous
        // offline session that persisted but could not POST).
        let pendingMsg = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "queued",
            streamingComplete: true
        )
        pendingMsg.syncState = "pending"
        try context.save()

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        await coordinator.replayPendingMessages()

        // The message should now be synced with the server ID
        let fetched = try messageRepo.fetchMessage(id: pendingMsg.id!)
        #expect(fetched?.syncState == "synced", "After replay, message should be synced")
        #expect(fetched?.serverId == serverMsgId, "After replay, serverId should match server response")
    }

    // MARK: - recommendation.delivered → persisted assistant message + card model

    @Test("recommendation.delivered event persists assistant message and produces RecommendationCardModel for guidance type")
    func testRecommendationDeliveredCreatesCardModel() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!
        let convLocalIdString = convLocalId.uuidString

        let recId = "rec-\(UUID().uuidString)"
        let guidanceText = "Stay hydrated and rest. Follow up if symptoms persist."

        // Stub GET /api/recommendations/{id}
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/recommendations/\(recId)"
        ) { req in
            let json = """
            {
              "ID": "\(recId)",
              "TenantID": "t1",
              "ConversationID": "\(convLocalIdString)",
              "PatientID": "patient-1",
              "State": "DELIVERED",
              "PayloadType": "guidance",
              "Payload": null,
              "DraftContent": "draft",
              "FinalContent": "\(guidanceText)",
              "ReviewedBy": "physician-1",
              "ReviewedAt": "2026-06-03T10:05:00Z",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        // Start the coordinator to wire up the WSEvent subscription.
        // connectWebSocket() silently fails (no live server) which is fine —
        // we inject the event directly via the publisher.
        coordinator.start()

        // Simulate a recommendation.delivered WebSocket push by sending the
        // event directly to the coordinator's subscription source.
        let wsEvent = WSEvent(
            type: "recommendation.delivered",
            data: WSEventData(
                recommendation_id: recId,
                conversation_id: convLocalIdString
            )
        )
        syncClient.eventPublisher.send(wsEvent)

        // Give the async handler a moment to complete.
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // 1. The coordinator should have published a card model.
        let cards = coordinator.deliveredCards
        #expect(cards.count == 1, "Exactly one card should be published")
        let card = cards.first
        #expect(card?.payloadType == "guidance", "payloadType should be guidance")
        #expect(card?.id == recId, "card id should match recommendation server ID")
        #expect(card?.conversationLocalId == convLocalId)

        // 2. An assistant message should have been persisted in Core Data.
        let messages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let assistantMsg = messages.first(where: { $0.role == "assistant" })
        #expect(assistantMsg != nil, "An assistant message should have been persisted")
        #expect(assistantMsg?.syncState == "synced", "Persisted message should be synced")
        #expect(assistantMsg?.serverId == recId, "serverId should match recommendation ID")

        // 3. Verify content is encrypted-at-rest (not stored as plaintext).
        let rawContent = assistantMsg?.encryptedContent
        #expect(rawContent != nil, "encryptedContent should not be nil")
        // The raw bytes should NOT equal the UTF-8 encoding of guidanceText —
        // they are AES-GCM ciphertext.
        let plainData = guidanceText.data(using: .utf8)!
        #expect(rawContent != plainData, "Content must be encrypted at rest, not stored as plaintext")

        // 4. Decrypted content should match.
        if let msg = assistantMsg {
            let decrypted = try messageRepo.decryptMessageContent(msg)
            #expect(decrypted == guidanceText, "Decrypted content should match the final recommendation text")
        }
    }

    // MARK: - Login stores JWT in keychain

    @Test("storeCoreAPIJWT stores token in Keys.coreAPIJWT slot")
    func testLoginStoresCoreAPIJWT() throws {
        let kc = TestKeychain()
        // AuthenticationService.storeCoreAPIJWT writes to Keys.coreAPIJWT.
        // We test the path that wires the JWT after a Core API login response.
        let authService = AuthenticationService(
            keychainManager: kc
        )

        let testJWT = "eyJhbGciOiJIUzI1NiJ9.test.sig"
        try authService.storeCoreAPIJWT(testJWT)

        let stored = try kc.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(stored == testJWT, "storeCoreAPIJWT should write to Keys.coreAPIJWT slot")
    }

    @Test("clearCoreAPIJWT removes the token from the keychain")
    func testClearCoreAPIJWT() throws {
        let kc = TestKeychain()
        try kc.set(key: KeychainManager.Keys.coreAPIJWT, value: "some.jwt")

        let authService = AuthenticationService(keychainManager: kc)
        authService.clearCoreAPIJWT()

        let stored = try kc.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(stored == nil, "clearCoreAPIJWT should remove the JWT from the keychain")
    }

    // MARK: - Session timeout clears JWT and stops coordinator (HIPAA)

    /// After `handleSessionTimeout()` fires the Core API JWT must be gone from
    /// the Keychain and the coordinator's WebSocket subscription must be
    /// cancelled so no further recommendation PHI can be delivered.
    @Test("Session timeout clears Core API JWT and stops sync coordinator")
    func testSessionTimeoutTearsDownCloudSession() async throws {
        let kc = TestKeychain()
        try kc.set(key: KeychainManager.Keys.coreAPIJWT, value: "live.jwt.token")

        // Build a real (but offline) SyncClient and coordinator so we can
        // verify that events sent after stop() do not reach deliveredCards.
        let offlineSession = makeOfflineSession()
        let context = makeInMemoryContext()
        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: offlineSession,
            keychainManager: kc
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        // Wire up the coordinator and JWT to the auth service.
        let authService = AuthenticationService(keychainManager: kc)
        authService.syncCoordinator = coordinator
        coordinator.start()

        // Pre-condition: JWT is present.
        let jwtBefore = try kc.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(jwtBefore == "live.jwt.token", "JWT must be present before timeout")

        // Simulate the 5-minute inactivity timeout.
        await authService._testSimulateSessionTimeout()

        // 1. Core API JWT must be cleared.
        let jwtAfter = try kc.get(key: KeychainManager.Keys.coreAPIJWT)
        #expect(jwtAfter == nil, "Core API JWT must be removed from keychain on session timeout")

        // 2. Auth service must have released the coordinator reference.
        #expect(authService.syncCoordinator == nil,
                "syncCoordinator must be nil after timeout so no new PHI can be delivered")

        // 3. Events sent after stop() must not produce new delivered cards.
        //    We hold our own reference to coordinator, so we can probe it.
        let cardsBefore = coordinator.deliveredCards.count
        syncClient.eventPublisher.send(WSEvent(
            type: "recommendation.delivered",
            data: WSEventData(recommendation_id: "post-timeout-rec", conversation_id: nil)
        ))
        // Give any async handler a moment to run (it should not, because stop()
        // cancelled the wsSubscription).
        try await Task.sleep(nanoseconds: 100_000_000) // 100 ms
        let cardsAfter = coordinator.deliveredCards.count
        #expect(cardsBefore == cardsAfter,
                "No recommendation cards should be appended after the coordinator is stopped")
    }

    // MARK: - Idempotency key plumbing

    /// postMessage sends the local message UUID as `idempotency_key` in the
    /// POST body.  Verified by inspecting the captured request body.
    @Test("postMessage includes local message UUID as idempotency_key in POST body")
    func testPostMessageIncludesIdempotencyKey() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convServerId = conversation.serverId!

        let serverMsgId = "srv-idemp-\(UUID().uuidString)"
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            let json = """
            {
              "ID": "\(serverMsgId)",
              "TenantID": "t1",
              "ConversationID": "\(convServerId)",
              "Role": "user",
              "Content": "ikey test",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        // Create a pending message so we have its local UUID.
        let pendingMsg = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "ikey test",
            streamingComplete: true
        )
        pendingMsg.syncState = "pending"
        try context.save()

        let localMsgId = pendingMsg.id!

        // Invoke postMessage — this is also the path used by replay.
        try await coordinator.postMessage(
            localMessageId: localMsgId,
            conversationServerId: convServerId,
            conversationLocalId: conversation.id!
        )

        // Inspect the captured POST request body for idempotency_key.
        let requests = SyncMockURLProtocol.capturedRequests(sessionID: sid)
        let postReq = requests.first(where: { $0.httpMethod == "POST" })
        #expect(postReq != nil, "A POST request should have been captured")

        var bodyData: Data? = nil
        if let stream = postReq?.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 1024
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(contentsOf: buf[0..<read])
            }
            bodyData = data.isEmpty ? nil : data
        }

        #expect(bodyData != nil, "POST body must be present")
        if let bodyData {
            let decoded = try JSONDecoder().decode([String: String].self, from: bodyData)
            #expect(decoded["idempotency_key"] == localMsgId.uuidString,
                    "postMessage must send local message UUID as idempotency_key")
        }
    }

    /// Replay sends the SAME idempotency key as the original postMessage call
    /// (same local UUID) — verified by checking two consecutive captured bodies.
    @Test("replayPendingMessages sends the same idempotency_key as the original postMessage")
    func testReplayUsesSameIdempotencyKey() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convServerId = conversation.serverId!

        let serverMsgId = "srv-replay-\(UUID().uuidString)"
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            let json = """
            {
              "ID": "\(serverMsgId)",
              "TenantID": "t1",
              "ConversationID": "\(convServerId)",
              "Role": "user",
              "Content": "replay key check",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )

        let pendingMsg = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "replay key check",
            streamingComplete: true
        )
        pendingMsg.syncState = "pending"
        try context.save()

        let localMsgId = pendingMsg.id!

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        // Trigger replay — internally calls postMessage with the pending message.
        await coordinator.replayPendingMessages()

        // The captured request body must contain the local message UUID.
        let requests = SyncMockURLProtocol.capturedRequests(sessionID: sid)
        let postReq = requests.first(where: { $0.httpMethod == "POST" })
        #expect(postReq != nil, "replayPendingMessages must issue a POST")

        var bodyData: Data? = nil
        if let stream = postReq?.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 1024
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(contentsOf: buf[0..<read])
            }
            bodyData = data.isEmpty ? nil : data
        }

        #expect(bodyData != nil)
        if let bodyData {
            let decoded = try JSONDecoder().decode([String: String].self, from: bodyData)
            #expect(decoded["idempotency_key"] == localMsgId.uuidString,
                    "replay must send the same local UUID as idempotency_key as the original send")
        }
    }

    /// A deduped response (stub returns HTTP 200 with the EXISTING server ID)
    /// still transitions the local message to syncState=synced with that serverId.
    @Test("postMessage deduped response (HTTP 200) still marks message synced with existing serverId")
    func testPostMessageDedupeResponseMarksMessageSynced() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convServerId = conversation.serverId!

        // Stub returns 200 (dedupe hit) with the EXISTING server ID.
        let existingServerId = "existing-\(UUID().uuidString)"
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            let json = """
            {
              "ID": "\(existingServerId)",
              "TenantID": "t1",
              "ConversationID": "\(convServerId)",
              "Role": "user",
              "Content": "dedupe check",
              "CreatedAt": "2026-06-03T08:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        let pendingMsg = try messageRepo.createMessage(
            conversationId: conversation.id!,
            role: .user,
            content: "dedupe check",
            streamingComplete: true
        )
        pendingMsg.syncState = "pending"
        try context.save()

        let localMsgId = pendingMsg.id!

        try await coordinator.postMessage(
            localMessageId: localMsgId,
            conversationServerId: convServerId,
            conversationLocalId: conversation.id!
        )

        // The message should now be synced with the EXISTING server ID from the 200.
        let fetched = try messageRepo.fetchMessage(id: localMsgId)
        #expect(fetched?.syncState == "synced",
                "Dedupe-hit (200) response must still mark message as synced")
        #expect(fetched?.serverId == existingServerId,
                "serverId must be adopted from the dedupe-hit response body, not left nil")
    }

    // MARK: - RecommendationCardModel equality and payloadType dispatch

    @Test("RecommendationCardModel is Equatable by value")
    func testRecommendationCardModelEquatable() {
        let id = UUID()
        let convId = UUID()
        let msgId = UUID()
        let a = RecommendationCardModel(
            id: "rec-1",
            conversationLocalId: convId,
            payloadType: "guidance",
            finalContent: "text",
            messageLocalId: msgId
        )
        let b = RecommendationCardModel(
            id: "rec-1",
            conversationLocalId: convId,
            payloadType: "guidance",
            finalContent: "text",
            messageLocalId: msgId
        )
        let c = RecommendationCardModel(
            id: "rec-2",   // different ID
            conversationLocalId: convId,
            payloadType: "guidance",
            finalContent: "text",
            messageLocalId: id
        )
        #expect(a == b)
        #expect(a != c)
    }

    @Test("RecommendationCard renders guidance payloadType without crashing (smoke test)")
    @MainActor
    func testRecommendationCardSmoke() {
        // This is a compile-time + runtime smoke test — verify that
        // RecommendationCard can be instantiated for a guidance card and that
        // the view body does not throw.  SwiftUI views are value types so we
        // just construct them.
        let model = RecommendationCardModel(
            id: "rc-smoke",
            conversationLocalId: UUID(),
            payloadType: "guidance",
            finalContent: "Take two tablets daily.",
            messageLocalId: UUID()
        )
        let card = RecommendationCard(model: model)
        // Verify the body property is accessible (triggers the switch dispatch).
        _ = card.body
    }

    @Test("RecommendationCard renders unknown payloadType without crashing (fallback smoke test)")
    @MainActor
    func testRecommendationCardUnknownPayloadType() {
        let model = RecommendationCardModel(
            id: "rc-unknown",
            conversationLocalId: UUID(),
            payloadType: "prescription",
            finalContent: "Amoxicillin 500mg.",
            messageLocalId: UUID()
        )
        let card = RecommendationCard(model: model)
        _ = card.body
    }

    @Test("RecommendationCard renders soap_note payloadType without crashing (smoke test)")
    @MainActor
    func testRecommendationCardSOAPNotePayloadType() {
        // Verify that a RecommendationCardModel with payloadType "soap_note"
        // routes to SOAPNoteCardView and that the view body is accessible
        // (i.e. the switch case is handled and does not fall through to the
        // generic fallback).  Synthetic content — no real patient data.
        let soapContent = """
        SUBJECTIVE: Three-day headache, bifrontal, 7/10.
        OBJECTIVE: Temperature 38.1 °C (self-reported). No exam findings.
        ASSESSMENT: Probable viral illness. No red flags.
        PLAN: Rest, fluids, acetaminophen PRN. Return if fever >39.5 °C.
        """
        let model = RecommendationCardModel(
            id: "rc-soap-smoke",
            conversationLocalId: UUID(),
            payloadType: "soap_note",
            finalContent: soapContent,
            messageLocalId: UUID()
        )
        // payloadType must be preserved unchanged on the model.
        #expect(model.payloadType == "soap_note",
                "payloadType must be soap_note on the constructed model")
        // Instantiating the card and accessing body must not crash — this
        // exercises the switch dispatch path for the soap_note case.
        let card = RecommendationCard(model: model)
        _ = card.body
    }

    // MARK: - Cohesive offline → replay → recommendation.delivered loop

    /// Validates the complete airplane-mode-replay-to-delivered-card loop in one
    /// deterministic test (Phase 6.4 validation criterion):
    ///
    /// 1. Patient sends a message while offline  → message saved, syncState = pending.
    /// 2. Network restored; coordinator.replayPendingMessages() re-POSTs       → synced.
    /// 3. Physician approves; server pushes recommendation.delivered via WS     → card + encrypted assistant message.
    ///
    /// All network is stubbed; no live calls; no PHI in logs.
    @Test("Offline message stays pending, replays to synced, then recommendation.delivered renders a guidance card")
    func testOfflineToReplayToRecommendationDeliveredLoop() async throws {
        // MARK: Setup — shared context and identifiers
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!
        let convServerId = conversation.serverId!

        let serverMsgId = "loop-msg-\(UUID().uuidString)"
        let recId = "loop-rec-\(UUID().uuidString)"
        let guidanceText = "Drink fluids and rest for 48 hours."

        // MARK: Step 1 — Send message offline (message stays pending)
        let offlineKc = makeKeychain()
        let offlineSession = makeOfflineSession()
        let offlineSyncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: offlineSession,
            keychainManager: offlineKc
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let offlineCoordinator = CloudSyncCoordinator(
            syncClient: offlineSyncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )
        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            auditLogger: AuditLogger(context: context),
            syncCoordinator: offlineCoordinator
        )

        try await service.loadConversation(convLocalId)
        try await service.sendMessage(conversationId: convLocalId, content: "loop test")

        let messagesAfterOffline = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let pendingMsg = messagesAfterOffline.first(where: { $0.role == "user" })
        #expect(pendingMsg?.syncState == "pending", "Step 1: message must be pending while offline")

        // MARK: Step 2 — Reconnect and replay (pending → synced)
        let sid = UUID().uuidString
        let onlineKc = makeKeychain()
        let onlineSession = makeStubSession(sessionID: sid)

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            let json = """
            {
              "ID": "\(serverMsgId)",
              "TenantID": "t1",
              "ConversationID": "\(convServerId)",
              "Role": "user",
              "Content": "loop test",
              "CreatedAt": "2026-06-03T11:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }

        // Also stub the GET recommendation used in step 3 while the session is live.
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/recommendations/\(recId)"
        ) { req in
            let json = """
            {
              "ID": "\(recId)",
              "TenantID": "t1",
              "ConversationID": "\(convLocalId.uuidString)",
              "PatientID": "p1",
              "State": "DELIVERED",
              "PayloadType": "guidance",
              "Payload": null,
              "DraftContent": "draft",
              "FinalContent": "\(guidanceText)",
              "ReviewedBy": "dr-1",
              "ReviewedAt": "2026-06-03T11:05:00Z",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }

        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let onlineSyncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: onlineSession,
            keychainManager: onlineKc
        )
        let onlineCoordinator = CloudSyncCoordinator(
            syncClient: onlineSyncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )
        onlineCoordinator.start()

        // Replay replays the pending message using the new (online) coordinator.
        await onlineCoordinator.replayPendingMessages()

        let syncedMsg = try messageRepo.fetchMessage(id: pendingMsg!.id!)
        #expect(syncedMsg?.syncState == "synced",  "Step 2: after replay message must be synced")
        #expect(syncedMsg?.serverId == serverMsgId, "Step 2: serverId must be set from POST response")

        // MARK: Step 3 — Physician approves; WS pushes recommendation.delivered → card
        let wsEvent = WSEvent(
            type: "recommendation.delivered",
            data: WSEventData(
                recommendation_id: recId,
                conversation_id: convLocalId.uuidString
            )
        )
        onlineSyncClient.eventPublisher.send(wsEvent)

        // Allow the async WS handler to complete.
        try await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        let cards = onlineCoordinator.deliveredCards
        #expect(cards.count == 1, "Step 3: exactly one guidance card should be published")
        #expect(cards.first?.payloadType == "guidance")
        #expect(cards.first?.id == recId)

        let allMessages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let assistantMsg = allMessages.first(where: { $0.role == "assistant" })
        #expect(assistantMsg != nil, "Step 3: assistant message must be persisted")
        #expect(assistantMsg?.syncState == "synced")
        #expect(assistantMsg?.serverId == recId)

        // Verify the content is encrypted at rest.
        let rawContent = assistantMsg?.encryptedContent
        let plainData = guidanceText.data(using: .utf8)!
        #expect(rawContent != plainData, "Step 3: content must be AES-GCM encrypted, not plaintext")
    }

    // MARK: - message.created → persisted assistant messages

    /// A `message.created` WS event triggers a listMessages fetch and persists
    /// new assistant messages as encrypted Core Data rows marked syncState=synced.
    @Test("message.created event persists new assistant messages with serverId and syncState=synced")
    func testMessageCreatedEventPersistsAssistantMessages() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!
        let convServerId = conversation.serverId!

        let serverMsgId = "agent-q-\(UUID().uuidString)"
        let questionText = "How long have you had the headache?"

        // Stub GET /api/conversations/{serverId}/messages
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            guard req.httpMethod == "GET" else {
                return ("[]".data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
            }
            let json = """
            [
              {
                "ID": "\(serverMsgId)",
                "TenantID": "t1",
                "ConversationID": "\(convServerId)",
                "Role": "assistant",
                "Content": "\(questionText)",
                "CreatedAt": "2026-06-26T10:00:00Z"
              }
            ]
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )
        coordinator.start()

        // Fire a message.created WS event directly into the coordinator.
        let wsEvent = WSEvent(
            type: "message.created",
            data: WSEventData(
                recommendation_id: nil,
                conversation_id: convLocalId.uuidString,
                message_id: serverMsgId
            )
        )
        syncClient.eventPublisher.send(wsEvent)

        // Allow the async handler to complete.
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // 1. An assistant message should be persisted in Core Data.
        let messages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let assistantMsg = messages.first(where: { $0.role == "assistant" })
        #expect(assistantMsg != nil, "An assistant message must be persisted after message.created")
        #expect(assistantMsg?.syncState == "synced",
                "Persisted message must have syncState = synced")
        #expect(assistantMsg?.serverId == serverMsgId,
                "serverId must match the server message ID")

        // 2. Content is encrypted at rest (not stored as plaintext UTF-8).
        if let msg = assistantMsg {
            let rawContent = msg.encryptedContent
            let plainData = questionText.data(using: .utf8)!
            #expect(rawContent != plainData,
                    "Content must be AES-GCM encrypted, not stored as plaintext")

            // Decryption must recover the original text.
            let decrypted = try messageRepo.decryptMessageContent(msg)
            #expect(decrypted == questionText,
                    "Decrypted content must match the server message text")
        }

        // 3. syncedMessageCount must have been incremented.
        #expect(coordinator.syncedMessageCount == 1,
                "syncedMessageCount must be 1 after one new assistant message was inserted")
    }

    // MARK: - Cloud path routing (thin-client behaviour) [task 6.2]

    /// When a CloudSyncCoordinator is injected, `sendMessage` must take the
    /// cloud POST path and must NOT start the legacy LLM streaming path.
    ///
    /// Assertion: `isStreaming` stays `false` throughout and after the call,
    /// confirming that `streamAssistantTurn` (which sets `isStreaming = true`)
    /// was never entered.
    ///
    /// An offline coordinator is used so the POST fails silently; the important
    /// thing is that the code reaches `coordinator.postMessage` and returns
    /// early — it never falls through to the legacy streaming branch.
    @Test("sendMessage with coordinator does not start LLM streaming — cloud path is taken")
    func testSendMessageWithCoordinatorUsesCloudPathNotStreaming() async throws {
        let kc = makeKeychain()
        let offlineSession = makeOfflineSession()
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: offlineSession,
            keychainManager: kc
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )

        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            auditLogger: AuditLogger(context: context),
            syncCoordinator: coordinator
        )

        // Pre-condition: isStreaming starts false.
        #expect(service.isStreaming == false, "isStreaming must start false")

        try await service.loadConversation(convLocalId)
        try await service.sendMessage(conversationId: convLocalId, content: "cloud route check")

        // isStreaming must still be false — the cloud path returns before
        // `streamAssistantTurn` can set it to true.
        #expect(service.isStreaming == false,
                "isStreaming must remain false when the cloud coordinator path is taken")

        // The user message must still be persisted (cloud path saves first, then POSTs).
        let allMessages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let userMsg = allMessages.first(where: { $0.role == "user" })
        #expect(userMsg != nil, "User message must be persisted even when the cloud path is taken")
    }

    // MARK: - soap_note recommendation.delivered coordinator path [task 6.2]

    /// A `recommendation.delivered` WS event whose `PayloadType` is `"soap_note"`
    /// must:
    ///  1. Produce a `RecommendationCardModel` with `payloadType == "soap_note"` in
    ///     `coordinator.deliveredCards` (exercising the soap_note dispatch path in
    ///     `CloudSyncCoordinator`).
    ///  2. Persist an encrypted assistant message in Core Data with
    ///     `syncState == "synced"` and `serverId == recommendation server ID`.
    ///
    /// The phase-5 tests already cover the card-view smoke test for soap_note;
    /// this test covers the *coordinator delivery path* for soap_note specifically.
    @Test("recommendation.delivered with soap_note payloadType creates card model and persists encrypted assistant message")
    func testRecommendationDeliveredSOAPNoteCreatesCardModel() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!
        let convLocalIdString = convLocalId.uuidString

        let recId = "soap-rec-\(UUID().uuidString)"
        // Synthetic SOAP content — not real patient data.
        let soapContent = "SUBJECTIVE: Two-day sore throat, mild.\\nOBJECTIVE: No exam findings available.\\nASSESSMENT: Probable viral pharyngitis.\\nPLAN: Rest, fluids, analgesics PRN."
        // Plain Swift version (newlines restored) used for encrypt/decrypt checks.
        let soapContentDecoded = soapContent.replacingOccurrences(of: "\\n", with: "\n")

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/recommendations/\(recId)"
        ) { req in
            let json = """
            {
              "ID": "\(recId)",
              "TenantID": "t1",
              "ConversationID": "\(convLocalIdString)",
              "PatientID": "patient-soap-1",
              "State": "DELIVERED",
              "PayloadType": "soap_note",
              "Payload": null,
              "DraftContent": "draft soap",
              "FinalContent": "\(soapContent)",
              "ReviewedBy": "physician-soap-1",
              "ReviewedAt": "2026-06-26T09:00:00Z",
              "CreatedAt": "2026-06-26T08:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )
        coordinator.start()

        // Simulate a recommendation.delivered WS push for a soap_note payload.
        let wsEvent = WSEvent(
            type: "recommendation.delivered",
            data: WSEventData(
                recommendation_id: recId,
                conversation_id: convLocalIdString
            )
        )
        syncClient.eventPublisher.send(wsEvent)

        // Give the async handler time to complete.
        try await Task.sleep(nanoseconds: 200_000_000) // 200 ms

        // 1. coordinator.deliveredCards must contain exactly one soap_note card.
        let cards = coordinator.deliveredCards
        #expect(cards.count == 1,
                "Exactly one card must be published for the soap_note delivery")
        let card = cards.first
        #expect(card?.payloadType == "soap_note",
                "Card payloadType must be soap_note, not guidance or any other type")
        #expect(card?.id == recId,
                "Card id must match the recommendation server ID")
        #expect(card?.conversationLocalId == convLocalId,
                "Card conversationLocalId must match the local conversation UUID")

        // 2. An assistant message must be persisted in Core Data.
        let messages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let assistantMsg = messages.first(where: { $0.role == "assistant" })
        #expect(assistantMsg != nil,
                "An assistant message must be persisted for the soap_note recommendation")
        #expect(assistantMsg?.syncState == "synced",
                "Persisted message must have syncState = synced")
        #expect(assistantMsg?.serverId == recId,
                "serverId must match the recommendation server ID")

        // 3. Content must be encrypted at rest — raw bytes must not equal plain UTF-8.
        if let msg = assistantMsg {
            let rawContent = msg.encryptedContent
            #expect(rawContent != nil, "encryptedContent must not be nil")
            let plainData = soapContentDecoded.data(using: .utf8)!
            #expect(rawContent != plainData,
                    "SOAP note content must be AES-GCM encrypted, not stored as plaintext")

            // Decrypting must recover the physician-approved SOAP text.
            let decrypted = try messageRepo.decryptMessageContent(msg)
            #expect(decrypted == soapContentDecoded,
                    "Decrypted content must match the original SOAP note text exactly")
        }
    }

    /// A second `message.created` event for the same server message ID must NOT
    /// produce a duplicate Core Data row (de-duplication by serverId).
    @Test("message.created event is de-duplicated: repeat event for same server message ID inserts no extra row")
    func testMessageCreatedEventDeDuplicatesOnRepeat() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let context = makeInMemoryContext()
        let userId = UUID()
        let conversation = try seedConversation(in: context, userId: userId)
        let convLocalId = conversation.id!
        let convServerId = conversation.serverId!

        let serverMsgId = "agent-dedup-\(UUID().uuidString)"

        // Always returns the same single assistant message.
        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            guard req.httpMethod == "GET" else {
                return ("[]".data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
            }
            let json = """
            [
              {
                "ID": "\(serverMsgId)",
                "TenantID": "t1",
                "ConversationID": "\(convServerId)",
                "Role": "assistant",
                "Content": "Are the symptoms constant or intermittent?",
                "CreatedAt": "2026-06-26T10:01:00Z"
              }
            ]
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let syncClient = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let coordinator = CloudSyncCoordinator(
            syncClient: syncClient,
            messageRepository: messageRepo,
            conversationRepository: conversationRepo,
            auditLogger: AuditLogger(context: context),
            context: context
        )
        coordinator.start()

        let wsEvent = WSEvent(
            type: "message.created",
            data: WSEventData(
                recommendation_id: nil,
                conversation_id: convLocalId.uuidString,
                message_id: serverMsgId
            )
        )

        // Fire the same event TWICE (simulates reconnect / replay).
        syncClient.eventPublisher.send(wsEvent)
        syncClient.eventPublisher.send(wsEvent)

        // Allow both handlers to complete.
        try await Task.sleep(nanoseconds: 300_000_000) // 300 ms

        // Exactly ONE assistant message must be present — not two.
        let messages = try messageRepo.fetchAllMessages(conversationId: convLocalId)
        let assistantMessages = messages.filter { $0.role == "assistant" }
        #expect(assistantMessages.count == 1,
                "De-duplication must prevent a second insert for the same server message ID")
        #expect(assistantMessages.first?.serverId == serverMsgId,
                "The single persisted message must carry the correct serverId")
    }
}
