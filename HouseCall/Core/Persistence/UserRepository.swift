//
//  UserRepository.swift
//  HouseCall
//
//  User Repository Protocol for Data Access Layer
//  Manages user CRUD operations with encryption integration
//

import Foundation
import CoreData

/// Errors that can occur during user repository operations
enum UserRepositoryError: LocalizedError {
    case invalidCredentials
    case encryptionFailed
    case decryptionFailed
    case invalidAuthMethod
    case userNotFound
    case saveFailed(Error)
    case fetchFailed(Error)
    case invalidEmail
    case invalidPassword
    case invalidPasscode

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password"
        case .encryptionFailed:
            return "Failed to encrypt user data"
        case .decryptionFailed:
            return "Failed to decrypt user data"
        case .invalidAuthMethod:
            return "Invalid authentication method specified"
        case .userNotFound:
            return "User account not found"
        case .saveFailed(let error):
            return "Failed to save user: \(error.localizedDescription)"
        case .fetchFailed(let error):
            return "Failed to fetch user: \(error.localizedDescription)"
        case .invalidEmail:
            return "Invalid email address format"
        case .invalidPassword:
            return "Invalid password"
        case .invalidPasscode:
            return "Invalid passcode"
        }
    }
}

/// Authentication method types
enum AuthMethod: String {
    case password = "password"
    case passcode = "passcode"
    case biometric = "biometric"
}

/// Protocol defining user data access operations
protocol UserRepositoryProtocol {
    /// Creates a new user account
    /// - Parameters:
    ///   - email: User's email address
    ///   - password: User's password (optional, for password auth)
    ///   - passcode: User's passcode (optional, for passcode auth)
    ///   - fullName: User's full name
    ///   - authMethod: Authentication method (password, passcode, or biometric)
    /// - Returns: Created User entity
    /// - Throws: UserRepositoryError
    func createUser(
        email: String,
        password: String?,
        passcode: String?,
        fullName: String,
        authMethod: AuthMethod
    ) throws -> User

    /// Finds a user by email address
    /// - Parameter email: Email address to search for
    /// - Returns: User entity if found, nil otherwise
    func findUser(by email: String) -> User?

    /// Finds a user by ID
    /// - Parameter id: User UUID
    /// - Returns: User entity if found, nil otherwise
    func findUser(by id: UUID) -> User?

    /// Updates an existing user
    /// - Parameter user: User entity to update
    /// - Throws: UserRepositoryError
    func updateUser(_ user: User) throws

    /// Authenticates a user with credentials
    /// - Parameters:
    ///   - email: User's email
    ///   - credential: Password or passcode
    ///   - authMethod: Authentication method being used
    /// - Returns: Authenticated User entity
    /// - Throws: UserRepositoryError
    func authenticateUser(email: String, credential: String, authMethod: AuthMethod) throws -> User

    /// Checks if an email is already registered
    /// - Parameter email: Email address to check
    /// - Returns: true if email exists, false otherwise
    func isEmailRegistered(_ email: String) -> Bool
}
