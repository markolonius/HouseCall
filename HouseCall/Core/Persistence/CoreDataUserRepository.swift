//
//  CoreDataUserRepository.swift
//  HouseCall
//
//  Core Data implementation of UserRepository
//  Handles encrypted user data storage and authentication
//

import Foundation
import CoreData

/// Core Data implementation of user repository
class CoreDataUserRepository: UserRepositoryProtocol {

    private let context: NSManagedObjectContext
    private let encryptionManager: EncryptionManager
    private let passwordHasher: PasswordHasher
    private let auditLogger: AuditLogger

    init(
        context: NSManagedObjectContext = PersistenceController.shared.container.viewContext,
        encryptionManager: EncryptionManager = .shared,
        passwordHasher: PasswordHasher = .shared,
        auditLogger: AuditLogger = .shared
    ) {
        self.context = context
        self.encryptionManager = encryptionManager
        self.passwordHasher = passwordHasher
        self.auditLogger = auditLogger
    }

    // MARK: - Create User

    func createUser(
        email: String,
        password: String?,
        passcode: String?,
        fullName: String,
        authMethod: AuthMethod
    ) throws -> User {
        // Create user entity
        let user = User(context: context)
        user.id = UUID()
        user.email = email.lowercased()
        user.createdAt = Date()
        user.authMethod = authMethod.rawValue
        user.accountStatus = "active"

        // Hash and encrypt credentials based on auth method
        switch authMethod {
        case .password:
            guard let password = password else {
                throw UserRepositoryError.invalidPassword
            }
            let hashedPassword = try passwordHasher.hash(password: password)
            user.encryptedPasswordHash = try encryptionManager.encrypt(
                data: hashedPassword,
                for: user.id!
            )
            user.encryptedPasscodeHash = nil

        case .passcode:
            guard let passcode = passcode else {
                throw UserRepositoryError.invalidPasscode
            }
            let hashedPasscode = try passwordHasher.hash(password: passcode)
            user.encryptedPasscodeHash = try encryptionManager.encrypt(
                data: hashedPasscode,
                for: user.id!
            )
            user.encryptedPasswordHash = nil

        case .biometric:
            // Biometric doesn't store credentials
            user.encryptedPasswordHash = nil
            user.encryptedPasscodeHash = nil
        }

        // Encrypt full name
        guard let nameData = fullName.data(using: .utf8) else {
            throw UserRepositoryError.encryptionFailed
        }
        user.encryptedFullName = try encryptionManager.encrypt(
            data: nameData,
            for: user.id!
        )

        // Save to Core Data
        do {
            try context.save()
        } catch {
            context.rollback()
            throw UserRepositoryError.saveFailed(error)
        }

        // Log audit event
        try? auditLogger.logAccountCreated(userId: user.id!, authMethod: authMethod.rawValue)

        return user
    }

    // MARK: - Find User

    func findUser(by email: String) -> User? {
        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "email == %@", email.lowercased())
        fetchRequest.fetchLimit = 1

        do {
            let users = try context.fetch(fetchRequest)
            return users.first
        } catch {
            return nil
        }
    }

    func findUser(by id: UUID) -> User? {
        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        fetchRequest.fetchLimit = 1

        do {
            let users = try context.fetch(fetchRequest)
            return users.first
        } catch {
            return nil
        }
    }

    // MARK: - Update User

    func updateUser(_ user: User) throws {
        guard user.managedObjectContext == context else {
            throw UserRepositoryError.saveFailed(
                NSError(domain: "UserRepository", code: -1,
                       userInfo: [NSLocalizedDescriptionKey: "User belongs to different context"])
            )
        }

        do {
            try context.save()
        } catch {
            context.rollback()
            throw UserRepositoryError.saveFailed(error)
        }
    }

    // MARK: - Authenticate User

    func authenticateUser(email: String, credential: String, authMethod: AuthMethod) throws -> User {
        // Find user
        guard let user = findUser(by: email) else {
            // Log failed login attempt
            try? auditLogger.logLoginFailure(
                email: email,
                reason: "User not found",
                authMethod: authMethod.rawValue
            )
            throw UserRepositoryError.invalidCredentials
        }

        // Verify auth method matches
        guard user.authMethod == authMethod.rawValue else {
            try? auditLogger.logLoginFailure(
                email: email,
                reason: "Authentication method mismatch",
                authMethod: authMethod.rawValue
            )
            throw UserRepositoryError.invalidAuthMethod
        }

        // Verify credentials based on auth method
        switch authMethod {
        case .password:
            guard let encryptedHash = user.encryptedPasswordHash else {
                throw UserRepositoryError.invalidCredentials
            }

            do {
                let hashedPassword = try encryptionManager.decrypt(
                    encryptedData: encryptedHash,
                    for: user.id!
                )

                if !passwordHasher.verify(password: credential, hash: hashedPassword) {
                    try? auditLogger.logLoginFailure(
                        email: email,
                        reason: "Invalid password",
                        authMethod: authMethod.rawValue
                    )
                    throw UserRepositoryError.invalidCredentials
                }
            } catch {
                throw UserRepositoryError.decryptionFailed
            }

        case .passcode:
            guard let encryptedHash = user.encryptedPasscodeHash else {
                throw UserRepositoryError.invalidCredentials
            }

            do {
                let hashedPasscode = try encryptionManager.decrypt(
                    encryptedData: encryptedHash,
                    for: user.id!
                )

                if !passwordHasher.verify(password: credential, hash: hashedPasscode) {
                    try? auditLogger.logLoginFailure(
                        email: email,
                        reason: "Invalid passcode",
                        authMethod: authMethod.rawValue
                    )
                    throw UserRepositoryError.invalidCredentials
                }
            } catch {
                throw UserRepositoryError.decryptionFailed
            }

        case .biometric:
            // Biometric auth is verified before calling this method
            // This just confirms the user exists and is active
            break
        }

        // Update last login timestamp
        user.lastLoginAt = Date()
        try? context.save()

        // Log successful login
        try? auditLogger.logLoginSuccess(userId: user.id!, authMethod: authMethod.rawValue)

        return user
    }

    // MARK: - Email Check

    func isEmailRegistered(_ email: String) -> Bool {
        return findUser(by: email) != nil
    }

    // MARK: - Helper Methods

    /// Decrypts user's full name
    /// - Parameter user: User entity
    /// - Returns: Decrypted full name
    func getDecryptedFullName(for user: User) throws -> String {
        guard let encryptedName = user.encryptedFullName,
              let userId = user.id else {
            throw UserRepositoryError.decryptionFailed
        }

        let decryptedData = try encryptionManager.decrypt(
            encryptedData: encryptedName,
            for: userId
        )

        guard let name = String(data: decryptedData, encoding: .utf8) else {
            throw UserRepositoryError.decryptionFailed
        }

        return name
    }
}
