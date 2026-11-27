//
//  ProviderlessConversationTests.swift
//  HouseCallTests
//
//  The app no longer chooses an LLM provider: conversations are created
//  without one and the legacy `llmProvider` attribute keeps its schema default.
//

import Testing
import CoreData
@testable import HouseCall

/// Records the provider each createConversation call receives.
private final class RecordingConversationRepository: CoreDataConversationRepository {
    var recordedProviders: [LLMProviderType?] = []

    override func createConversation(
        userId: UUID,
        provider: LLMProviderType?,
        title: String? = nil
    ) throws -> Conversation {
        recordedProviders.append(provider)
        return try super.createConversation(userId: userId, provider: provider, title: title)
    }
}

@Suite("Providerless Conversation Tests")
@MainActor
struct ProviderlessConversationTests {

    private func makeContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "HouseCall", managedObjectModel: TestCoreDataModel.shared)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }
        return container.viewContext
    }

    private func makeRepository(_ context: NSManagedObjectContext) -> RecordingConversationRepository {
        RecordingConversationRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
    }

    @Test("Repository creates a conversation without a provider and keeps the schema default")
    func repositoryWithoutProvider() throws {
        let context = makeContext()
        let repository = makeRepository(context)
        let userId = UUID()

        let conversation = try repository.createConversation(userId: userId, title: nil)

        #expect(conversation.userId == userId)
        #expect(conversation.id != nil)
        #expect(conversation.isActive == true)
        #expect(conversation.llmProvider == "openai") // Core Data schema default
        #expect(repository.recordedProviders.count == 1)
        #expect(repository.recordedProviders[0] == nil)
    }

    @Test("Service first-launch path passes no provider to the repository")
    func serviceWithoutProvider() async throws {
        let context = makeContext()
        let repository = makeRepository(context)
        let userId = UUID()
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        let service = AIConversationService(
            userId: userId,
            conversationRepository: repository,
            messageRepository: messageRepo,
            auditLogger: AuditLogger(context: context),
            syncCoordinator: nil
        )

        let conversation = try await service.createConversation()

        #expect(conversation.llmProvider == "openai") // schema default, not a chosen provider
        #expect(repository.recordedProviders.count == 1)
        #expect(repository.recordedProviders[0] == nil)
    }
}
