//
//  MessageRepository.swift
//  HouseCall
//
//  Message Repository Protocol for Data Access Layer
//  Manages message CRUD operations with encryption integration
//

import Foundation
import CoreData

/// Errors that can occur during message repository operations
enum MessageRepositoryError: LocalizedError, Equatable {
    case encryptionFailed
    case decryptionFailed
    case messageNotFound
    case conversationNotFound
    case saveFailed(Error)
    case fetchFailed(Error)
    case deleteFailed(Error)
    case invalidRole
    case invalidContent

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt message content"
        case .decryptionFailed:
            return "Failed to decrypt message content"
        case .messageNotFound:
            return "Message not found"
        case .conversationNotFound:
            return "Conversation not found"
        case .saveFailed(let error):
            return "Failed to save message: \(error.localizedDescription)"
        case .fetchFailed(let error):
            return "Failed to fetch messages: \(error.localizedDescription)"
        case .deleteFailed(let error):
            return "Failed to delete messages: \(error.localizedDescription)"
        case .invalidRole:
            return "Invalid message role"
        case .invalidContent:
            return "Invalid message content"
        }
    }

    // Custom Equatable implementation
    static func == (lhs: MessageRepositoryError, rhs: MessageRepositoryError) -> Bool {
        switch (lhs, rhs) {
        case (.encryptionFailed, .encryptionFailed),
             (.decryptionFailed, .decryptionFailed),
             (.messageNotFound, .messageNotFound),
             (.conversationNotFound, .conversationNotFound),
             (.invalidRole, .invalidRole),
             (.invalidContent, .invalidContent):
            return true
        case (.saveFailed, .saveFailed),
             (.fetchFailed, .fetchFailed),
             (.deleteFailed, .deleteFailed):
            // For errors with associated values, we consider them equal by case only
            return true
        default:
            return false
        }
    }
}

/// Message role types
enum MessageRole: String {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
}

/// Protocol defining message data access operations
protocol MessageRepositoryProtocol {
    /// Creates a new message in a conversation
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - role: Message role (user, assistant, system)
    ///   - content: Message content (will be encrypted)
    ///   - streamingComplete: Whether the message is complete (for streaming responses)
    /// - Returns: Created Message entity
    /// - Throws: MessageRepositoryError
    func createMessage(
        conversationId: UUID,
        role: MessageRole,
        content: String,
        streamingComplete: Bool
    ) throws -> Message

    /// Fetches messages for a conversation with pagination
    /// - Parameters:
    ///   - conversationId: UUID of the conversation
    ///   - limit: Maximum number of messages to fetch
    ///   - offset: Number of messages to skip (for pagination)
    /// - Returns: Array of Message entities sorted by timestamp ascending
    /// - Throws: MessageRepositoryError
    func fetchMessages(
        conversationId: UUID,
        limit: Int,
        offset: Int
    ) throws -> [Message]

    /// Fetches all messages for a conversation
    /// - Parameter conversationId: UUID of the conversation
    /// - Returns: Array of all Message entities sorted by timestamp ascending
    /// - Throws: MessageRepositoryError
    func fetchAllMessages(conversationId: UUID) throws -> [Message]

    /// Fetches a specific message by ID
    /// - Parameter id: Message UUID
    /// - Returns: Message entity if found, nil otherwise
    /// - Throws: MessageRepositoryError
    func fetchMessage(id: UUID) throws -> Message?

    /// Updates a message's content (used during streaming)
    /// - Parameters:
    ///   - id: Message UUID
    ///   - content: New content (will be encrypted)
    ///   - complete: Whether streaming is complete
    ///   - tokenCount: Number of tokens used (optional)
    /// - Throws: MessageRepositoryError
    func updateMessageContent(
        id: UUID,
        content: String,
        complete: Bool,
        tokenCount: Int32?
    ) throws

    /// Deletes all messages in a conversation
    /// - Parameter conversationId: UUID of the conversation
    /// - Throws: MessageRepositoryError
    func deleteMessages(conversationId: UUID) throws

    /// Deletes a specific message
    /// - Parameter id: Message UUID
    /// - Throws: MessageRepositoryError
    func deleteMessage(id: UUID) throws

    /// Decrypts a message's content
    /// - Parameter message: Message entity
    /// - Returns: Decrypted content string
    /// - Throws: MessageRepositoryError
    func decryptMessageContent(_ message: Message) throws -> String

    /// Gets the user ID associated with a conversation
    /// - Parameter conversationId: UUID of the conversation
    /// - Returns: User UUID
    /// - Throws: MessageRepositoryError
    func getUserId(for conversationId: UUID) throws -> UUID
}
