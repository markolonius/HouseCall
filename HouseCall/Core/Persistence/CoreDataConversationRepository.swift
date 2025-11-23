//
//  CoreDataConversationRepository.swift
//  HouseCall
//
//  Core Data implementation of ConversationRepository
//  Handles encrypted conversation data storage
//

import Foundation
import CoreData

/// Core Data implementation of conversation repository
class CoreDataConversationRepository: ConversationRepositoryProtocol {

    private let context: NSManagedObjectContext
    private let encryptionManager: EncryptionManager
    private let auditLogger: AuditLogger

    init(
        context: NSManagedObjectContext = PersistenceController.shared.container.viewContext,
        encryptionManager: EncryptionManager = .shared,
        auditLogger: AuditLogger = .shared
    ) {
        self.context = context
        self.encryptionManager = encryptionManager
        self.auditLogger = auditLogger
    }

    // MARK: - Create Conversation

    func createConversation(
        userId: UUID,
        provider: LLMProviderType,
        title: String? = nil
    ) throws -> Conversation {
        // Create conversation entity
        let conversation = Conversation(context: context)
        conversation.id = UUID()
        conversation.userId = userId
        conversation.createdAt = Date()
        conversation.updatedAt = Date()
        conversation.isActive = true
        conversation.llmProvider = provider.rawValue

        // Encrypt title if provided
        if let title = title, !title.isEmpty {
            guard let titleData = title.data(using: .utf8) else {
                throw ConversationRepositoryError.encryptionFailed
            }
            conversation.encryptedTitle = try encryptionManager.encrypt(
                data: titleData,
                for: userId
            )
        } else {
            // Empty encrypted title
            conversation.encryptedTitle = Data()
        }

        // Save to Core Data
        do {
            try context.save()
        } catch {
            context.rollback()
            throw ConversationRepositoryError.saveFailed(error)
        }

        // Log audit event
        try? auditLogger.log(
            eventType: .conversationCreated,
            userId: userId,
            details: [
                "conversationId": conversation.id!.uuidString,
                "provider": provider.rawValue
            ]
        )

        return conversation
    }

    // MARK: - Fetch Conversations

    func fetchConversations(userId: UUID) throws -> [Conversation] {
        let fetchRequest: NSFetchRequest<Conversation> = Conversation.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "userId == %@", userId as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "updatedAt", ascending: false)]

        do {
            let conversations = try context.fetch(fetchRequest)
            return conversations
        } catch {
            throw ConversationRepositoryError.fetchFailed(error)
        }
    }

    func fetchConversation(id: UUID) throws -> Conversation? {
        let fetchRequest: NSFetchRequest<Conversation> = Conversation.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1

        do {
            let conversations = try context.fetch(fetchRequest)
            return conversations.first
        } catch {
            throw ConversationRepositoryError.fetchFailed(error)
        }
    }

    // MARK: - Update Conversation

    func updateConversationTitle(id: UUID, title: String) throws {
        guard let conversation = try fetchConversation(id: id) else {
            throw ConversationRepositoryError.conversationNotFound
        }

        // Encrypt new title
        guard let titleData = title.data(using: .utf8) else {
            throw ConversationRepositoryError.encryptionFailed
        }
        conversation.encryptedTitle = try encryptionManager.encrypt(
            data: titleData,
            for: conversation.userId!
        )
        conversation.updatedAt = Date()

        do {
            try context.save()
        } catch {
            context.rollback()
            throw ConversationRepositoryError.saveFailed(error)
        }
    }

    func updateConversationTimestamp(id: UUID, timestamp: Date) throws {
        guard let conversation = try fetchConversation(id: id) else {
            throw ConversationRepositoryError.conversationNotFound
        }

        conversation.updatedAt = timestamp

        do {
            try context.save()
        } catch {
            context.rollback()
            throw ConversationRepositoryError.saveFailed(error)
        }
    }

    func updateConversationProvider(id: UUID, provider: LLMProviderType) throws {
        guard let conversation = try fetchConversation(id: id) else {
            throw ConversationRepositoryError.conversationNotFound
        }

        let oldProvider = conversation.llmProvider
        conversation.llmProvider = provider.rawValue
        conversation.updatedAt = Date()

        do {
            try context.save()
        } catch {
            context.rollback()
            throw ConversationRepositoryError.saveFailed(error)
        }

        // Log audit event for provider switch
        try? auditLogger.log(
            eventType: .conversationProviderSwitched,
            userId: conversation.userId!,
            details: [
                "conversationId": conversation.id!.uuidString,
                "oldProvider": oldProvider ?? "unknown",
                "newProvider": provider.rawValue
            ]
        )
    }

    // MARK: - Delete Conversation

    func deleteConversation(id: UUID) throws {
        guard let conversation = try fetchConversation(id: id) else {
            throw ConversationRepositoryError.conversationNotFound
        }

        let userId = conversation.userId!
        let messageCount = conversation.messages?.count ?? 0

        // Delete conversation (cascade will delete messages)
        context.delete(conversation)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw ConversationRepositoryError.deleteFailed(error)
        }

        // Log audit event
        try? auditLogger.log(
            eventType: .conversationDeleted,
            userId: userId,
            details: [
                "conversationId": id.uuidString,
                "messageCount": messageCount
            ]
        )
    }

    // MARK: - Decrypt Title

    func decryptConversationTitle(_ conversation: Conversation) throws -> String {
        guard let userId = conversation.userId else {
            throw ConversationRepositoryError.invalidUserId
        }

        // Handle empty title
        guard let encryptedTitle = conversation.encryptedTitle, !encryptedTitle.isEmpty else {
            return ""
        }

        do {
            let decryptedData = try encryptionManager.decrypt(
                data: encryptedTitle,
                for: userId
            )
            guard let title = String(data: decryptedData, encoding: .utf8) else {
                throw ConversationRepositoryError.decryptionFailed
            }
            return title
        } catch {
            throw ConversationRepositoryError.decryptionFailed
        }
    }
}
