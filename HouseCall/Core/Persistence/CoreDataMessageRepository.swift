//
//  CoreDataMessageRepository.swift
//  HouseCall
//
//  Core Data implementation of MessageRepository
//  Handles encrypted message data storage with pagination
//

import Foundation
import CoreData

/// Core Data implementation of message repository
class CoreDataMessageRepository: MessageRepositoryProtocol {

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

    // MARK: - Create Message

    func createMessage(
        conversationId: UUID,
        role: MessageRole,
        content: String,
        streamingComplete: Bool = true
    ) throws -> Message {
        // Fetch conversation to get userId for encryption
        let userId = try getUserId(for: conversationId)

        // Create message entity
        let message = Message(context: context)
        message.id = UUID()
        message.conversationId = conversationId
        message.role = role.rawValue
        message.timestamp = Date()
        message.streamingComplete = streamingComplete
        message.tokenCount = 0

        // Encrypt content
        guard let contentData = content.data(using: .utf8) else {
            throw MessageRepositoryError.encryptionFailed
        }
        message.encryptedContent = try encryptionManager.encrypt(
            data: contentData,
            for: userId
        )

        // Link to conversation
        let conversationFetch: NSFetchRequest<Conversation> = Conversation.fetchRequest()
        conversationFetch.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)
        if let conversation = try? context.fetch(conversationFetch).first {
            message.conversation = conversation
        }

        // Save to Core Data
        do {
            try context.save()
        } catch {
            context.rollback()
            throw MessageRepositoryError.saveFailed(error)
        }

        // Log audit event (no content in logs for PHI protection)
        try? auditLogger.log(
            eventType: .messageCreated,
            userId: userId,
            details: [
                "messageId": message.id!.uuidString,
                "conversationId": conversationId.uuidString,
                "role": role.rawValue,
                "streamingComplete": String(streamingComplete)
            ]
        )

        return message
    }

    // MARK: - Fetch Messages

    func fetchMessages(
        conversationId: UUID,
        limit: Int = 50,
        offset: Int = 0
    ) throws -> [Message] {
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "conversationId == %@", conversationId as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        fetchRequest.fetchLimit = limit
        fetchRequest.fetchOffset = offset

        do {
            let messages = try context.fetch(fetchRequest)
            return messages
        } catch {
            throw MessageRepositoryError.fetchFailed(error)
        }
    }

    func fetchAllMessages(conversationId: UUID) throws -> [Message] {
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "conversationId == %@", conversationId as CVarArg)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        do {
            let messages = try context.fetch(fetchRequest)
            return messages
        } catch {
            throw MessageRepositoryError.fetchFailed(error)
        }
    }

    func fetchMessage(id: UUID) throws -> Message? {
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1

        do {
            let messages = try context.fetch(fetchRequest)
            return messages.first
        } catch {
            throw MessageRepositoryError.fetchFailed(error)
        }
    }

    // MARK: - Update Message

    func updateMessageContent(
        id: UUID,
        content: String,
        complete: Bool,
        tokenCount: Int32? = nil
    ) throws {
        guard let message = try fetchMessage(id: id) else {
            throw MessageRepositoryError.messageNotFound
        }

        // Get userId from conversation for encryption
        let userId = try getUserId(for: message.conversationId!)

        // Encrypt new content
        guard let contentData = content.data(using: .utf8) else {
            throw MessageRepositoryError.encryptionFailed
        }
        message.encryptedContent = try encryptionManager.encrypt(
            data: contentData,
            for: userId
        )
        message.streamingComplete = complete

        if let tokenCount = tokenCount {
            message.tokenCount = tokenCount
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw MessageRepositoryError.saveFailed(error)
        }
    }

    // MARK: - Delete Messages

    func deleteMessages(conversationId: UUID) throws {
        let fetchRequest: NSFetchRequest<Message> = Message.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "conversationId == %@", conversationId as CVarArg)

        do {
            let messages = try context.fetch(fetchRequest)
            for message in messages {
                context.delete(message)
            }
            try context.save()
        } catch {
            context.rollback()
            throw MessageRepositoryError.deleteFailed(error)
        }
    }

    func deleteMessage(id: UUID) throws {
        guard let message = try fetchMessage(id: id) else {
            throw MessageRepositoryError.messageNotFound
        }

        context.delete(message)

        do {
            try context.save()
        } catch {
            context.rollback()
            throw MessageRepositoryError.deleteFailed(error)
        }
    }

    // MARK: - Decrypt Content

    func decryptMessageContent(_ message: Message) throws -> String {
        guard let conversationId = message.conversationId else {
            throw MessageRepositoryError.conversationNotFound
        }

        let userId = try getUserId(for: conversationId)

        guard let encryptedContent = message.encryptedContent, !encryptedContent.isEmpty else {
            return ""
        }

        do {
            let decryptedData = try encryptionManager.decrypt(
                data: encryptedContent,
                for: userId
            )
            guard let content = String(data: decryptedData, encoding: .utf8) else {
                throw MessageRepositoryError.decryptionFailed
            }
            return content
        } catch {
            throw MessageRepositoryError.decryptionFailed
        }
    }

    // MARK: - Helper Methods

    func getUserId(for conversationId: UUID) throws -> UUID {
        let fetchRequest: NSFetchRequest<Conversation> = Conversation.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", conversationId as CVarArg)
        fetchRequest.fetchLimit = 1

        do {
            guard let conversation = try context.fetch(fetchRequest).first else {
                throw MessageRepositoryError.conversationNotFound
            }
            guard let userId = conversation.userId else {
                throw MessageRepositoryError.conversationNotFound
            }
            return userId
        } catch {
            throw MessageRepositoryError.fetchFailed(error)
        }
    }
}
