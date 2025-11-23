//
//  ConversationRepository.swift
//  HouseCall
//
//  Conversation Repository Protocol for Data Access Layer
//  Manages conversation CRUD operations with encryption integration
//

import Foundation
import CoreData

/// Errors that can occur during conversation repository operations
enum ConversationRepositoryError: LocalizedError, Equatable {
    case encryptionFailed
    case decryptionFailed
    case conversationNotFound
    case saveFailed(Error)
    case fetchFailed(Error)
    case invalidUserId
    case invalidProvider
    case deleteFailed(Error)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt conversation data"
        case .decryptionFailed:
            return "Failed to decrypt conversation data"
        case .conversationNotFound:
            return "Conversation not found"
        case .saveFailed(let error):
            return "Failed to save conversation: \(error.localizedDescription)"
        case .fetchFailed(let error):
            return "Failed to fetch conversation: \(error.localizedDescription)"
        case .invalidUserId:
            return "Invalid user ID"
        case .invalidProvider:
            return "Invalid LLM provider specified"
        case .deleteFailed(let error):
            return "Failed to delete conversation: \(error.localizedDescription)"
        }
    }

    // Custom Equatable implementation
    static func == (lhs: ConversationRepositoryError, rhs: ConversationRepositoryError) -> Bool {
        switch (lhs, rhs) {
        case (.encryptionFailed, .encryptionFailed),
             (.decryptionFailed, .decryptionFailed),
             (.conversationNotFound, .conversationNotFound),
             (.invalidUserId, .invalidUserId),
             (.invalidProvider, .invalidProvider):
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

/// LLM Provider types
enum LLMProviderType: String, CaseIterable {
    case openai = "openai"
    case claude = "claude"
    case custom = "custom"
}

/// Protocol defining conversation data access operations
protocol ConversationRepositoryProtocol {
    /// Creates a new conversation
    /// - Parameters:
    ///   - userId: User's UUID who owns the conversation
    ///   - provider: LLM provider type (openai, claude, custom)
    ///   - title: Optional initial title (will be encrypted)
    /// - Returns: Created Conversation entity
    /// - Throws: ConversationRepositoryError
    func createConversation(
        userId: UUID,
        provider: LLMProviderType,
        title: String?
    ) throws -> Conversation

    /// Fetches all conversations for a specific user
    /// - Parameter userId: User's UUID
    /// - Returns: Array of Conversation entities sorted by updatedAt descending
    /// - Throws: ConversationRepositoryError
    func fetchConversations(userId: UUID) throws -> [Conversation]

    /// Fetches a specific conversation by ID
    /// - Parameter id: Conversation UUID
    /// - Returns: Conversation entity if found, nil otherwise
    /// - Throws: ConversationRepositoryError
    func fetchConversation(id: UUID) throws -> Conversation?

    /// Updates a conversation's title
    /// - Parameters:
    ///   - id: Conversation UUID
    ///   - title: New title (will be encrypted)
    /// - Throws: ConversationRepositoryError
    func updateConversationTitle(id: UUID, title: String) throws

    /// Updates a conversation's last updated timestamp
    /// - Parameters:
    ///   - id: Conversation UUID
    ///   - timestamp: New timestamp
    /// - Throws: ConversationRepositoryError
    func updateConversationTimestamp(id: UUID, timestamp: Date) throws

    /// Updates a conversation's provider
    /// - Parameters:
    ///   - id: Conversation UUID
    ///   - provider: New LLM provider type
    /// - Throws: ConversationRepositoryError
    func updateConversationProvider(id: UUID, provider: LLMProviderType) throws

    /// Deletes a conversation and all its messages (cascade delete)
    /// - Parameter id: Conversation UUID
    /// - Throws: ConversationRepositoryError
    func deleteConversation(id: UUID) throws

    /// Decrypts a conversation's title
    /// - Parameter conversation: Conversation entity
    /// - Returns: Decrypted title string
    /// - Throws: ConversationRepositoryError
    func decryptConversationTitle(_ conversation: Conversation) throws -> String
}
