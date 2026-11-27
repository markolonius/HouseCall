//
//  ReadOnlyChatTests.swift
//  HouseCallTests
//
//  Task 2.2: with no valid Core API token the chat is read-only (history
//  stays readable, sending is blocked, sign-in is offered) and signing in
//  reactivates cloud sync in place, without restarting the app.
//

import Testing
import Foundation
import CoreData
@testable import HouseCall

private final class MemoryKeychain: KeychainManager {
    private var store: [String: String] = [:]
    override func set(key: String, value: String) throws { store[key] = value }
    override func get(key: String) throws -> String? { store[key] }
    override func delete(key: String) throws { store.removeValue(forKey: key) }
}

private struct SignInRejected: Error {}

@Suite("Read-only chat without a valid token")
@MainActor
struct ReadOnlyChatTests {

    private let userId = UUID()
    private let serverConvId = "server-conv-ro"

    private struct Fixture {
        let context: NSManagedObjectContext
        let conversationRepo: CoreDataConversationRepository
        let messageRepo: CoreDataMessageRepository
        let conversationId: UUID
    }

    private func makeFixture() throws -> Fixture {
        let container = NSPersistentContainer(name: "HouseCall", managedObjectModel: TestCoreDataModel.shared)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error { fatalError("in-memory store: \(error)") }
        }
        let context = container.viewContext
        let conversationRepo = CoreDataConversationRepository(
            context: context, encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context))
        let messageRepo = CoreDataMessageRepository(
            context: context, encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context))
        let conversation = try conversationRepo.createConversation(userId: userId, title: nil)
        conversation.serverId = serverConvId
        try context.save()
        return Fixture(context: context, conversationRepo: conversationRepo,
                       messageRepo: messageRepo, conversationId: conversation.id!)
    }

    /// Builds a coordinator whose message POSTs return `status` (401 or 201).
    private func makeCoordinator(_ f: Fixture, status: Int, sessionID: String) throws -> CloudSyncCoordinator {
        let convServerId = serverConvId
        SyncMockURLProtocol.register(
            sessionID: sessionID, path: "/api/conversations/\(convServerId)/messages"
        ) { req in
            let body = status == 201
                ? "{\"ID\":\"srv-msg-1\",\"TenantID\":\"t1\",\"ConversationID\":\"\(convServerId)\",\"Role\":\"user\",\"Content\":\"x\",\"CreatedAt\":\"2026-06-03T10:00:00Z\"}"
                : "{\"error\":\"unauthorized\"}"
            return (body.data(using: .utf8)!,
                    HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SyncMockURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Test-Session-ID": sessionID]
        let keychain = MemoryKeychain()
        try keychain.set(key: KeychainManager.Keys.coreAPIJWT, value: "test.jwt.token")
        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: URLSession(configuration: config),
            keychainManager: keychain)
        return CloudSyncCoordinator(
            syncClient: client, messageRepository: f.messageRepo,
            conversationRepository: f.conversationRepo,
            auditLogger: AuditLogger(context: f.context), context: f.context)
    }

    private func makeViewModel(
        _ f: Fixture,
        coordinator: CloudSyncCoordinator?,
        cloudSignIn: ConversationViewModel.CloudSignIn?
    ) -> ConversationViewModel {
        let service = AIConversationService(
            userId: userId, conversationRepository: f.conversationRepo,
            messageRepository: f.messageRepo, auditLogger: AuditLogger(context: f.context),
            syncCoordinator: coordinator)
        return ConversationViewModel(
            userId: userId, conversationId: f.conversationId,
            conversationRepository: f.conversationRepo, messageRepository: f.messageRepo,
            aiService: service, signInEmail: "patient@example.com", cloudSignIn: cloudSignIn)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @Test("No coordinator: view model is read-only and history stays readable")
    func missingTokenIsReadOnly() async throws {
        let f = try makeFixture()
        _ = try f.messageRepo.createMessage(
            conversationId: f.conversationId, role: .assistant, content: "cached", streamingComplete: true)
        let vm = makeViewModel(f, coordinator: nil, cloudSignIn: nil)

        vm.loadMessages()
        try await waitUntil { vm.messages.count == 1 }

        #expect(vm.cloudState == .signInRequired)
        #expect(vm.isReadOnly)
        #expect(vm.messages.count == 1, "cached history stays visible")
        #expect(vm.signInEmail == "patient@example.com")
    }

    @Test("Failed sign-in keeps the chat read-only")
    func failedSignInStaysReadOnly() async throws {
        let f = try makeFixture()
        let vm = makeViewModel(f, coordinator: nil, cloudSignIn: { _ in throw SignInRejected() })

        let ok = await vm.signIn(password: "wrong")

        #expect(!ok)
        #expect(vm.isReadOnly)
        #expect(vm.signInError != nil)
        #expect(vm.signInError?.contains("wrong") == false, "error must not echo the credential")
    }

    @Test("Sign-in with no coordinator activates cloud sync in place")
    func signInActivatesWithoutRestart() async throws {
        let f = try makeFixture()
        let sid = UUID().uuidString
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }
        let fresh = try makeCoordinator(f, status: 201, sessionID: sid)
        let vm = makeViewModel(f, coordinator: nil, cloudSignIn: { _ in fresh })
        #expect(vm.isReadOnly)

        let ok = await vm.signIn(password: "pw")

        #expect(ok)
        #expect(vm.cloudState == .active)
        #expect(!vm.isReadOnly)
        await vm.sendMessage(content: "hello after sign-in")
        let sent = try f.messageRepo.fetchAllMessages(conversationId: f.conversationId)
        #expect(sent.count == 1)
        #expect(sent.first?.syncState == "synced")
    }

    @Test("401 -> read-only -> sign in -> active, end to end")
    func expiredTokenEndToEnd() async throws {
        let f = try makeFixture()
        let staleSid = UUID().uuidString
        let freshSid = UUID().uuidString
        defer {
            SyncMockURLProtocol.cleanup(sessionID: staleSid)
            SyncMockURLProtocol.cleanup(sessionID: freshSid)
        }
        let stale = try makeCoordinator(f, status: 401, sessionID: staleSid)
        let fresh = try makeCoordinator(f, status: 201, sessionID: freshSid)
        let auth = FakeCoreAPIAuthClient()
        let vm = makeViewModel(f, coordinator: stale, cloudSignIn: { password in
            _ = try await auth.login(tenantId: FakeCoreAPIAuthClient.tenantId,
                                     email: "patient@example.com", password: password)
            return fresh
        })
        #expect(vm.cloudState == .active)

        // 401 on send: the coordinator deactivates and the chat turns read-only.
        await vm.sendMessage(content: "first")
        try await waitUntil { vm.isReadOnly }
        #expect(stale.requiresReauth)
        #expect(vm.cloudState == .signInRequired)

        // A further send is refused without touching the network or storing a message.
        let before = try f.messageRepo.fetchAllMessages(conversationId: f.conversationId).count
        await vm.sendMessage(content: "blocked")
        let after = try f.messageRepo.fetchAllMessages(conversationId: f.conversationId).count
        #expect(after == before)
        #expect(vm.errorMessage == AIConversationError.signInRequired.localizedDescription)

        // Sign in again: sync reactivates in the same view model / service.
        let ok = await vm.signIn(password: "pw")
        #expect(ok)
        #expect(vm.cloudState == .active)
        #expect(vm.errorMessage == nil)

        await vm.sendMessage(content: "second")
        let messages = try f.messageRepo.fetchAllMessages(conversationId: f.conversationId)
        let second = try messages.first { try f.messageRepo.decryptMessageContent($0) == "second" }
        #expect(second?.syncState == "synced")
    }
}
