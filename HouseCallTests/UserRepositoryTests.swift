//
//  UserRepositoryTests.swift
//  HouseCallTests
//
//  Unit tests for User Repository
//

import Testing
import CoreData
@testable import HouseCall

@Suite("UserRepository Tests")
struct UserRepositoryTests {

    // MARK: - Test Infrastructure

    /// Creates an in-memory Core Data stack for testing
    func createInMemoryContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(name: "HouseCall")
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]

        container.loadPersistentStores { description, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }

        return container.viewContext
    }

    // MARK: - Create User Tests

    @Test("Create user with password auth")
    func testCreateUserWithPassword() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let user = try repository.createUser(
            email: "test@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "John Doe",
            authMethod: .password
        )

        #expect(user.email == "test@example.com")
        #expect(user.authMethod == "password")
        #expect(user.encryptedPasswordHash != nil)
        #expect(user.encryptedPasscodeHash == nil)
        #expect(user.accountStatus == "active")
        #expect(user.id != nil)
    }

    @Test("Create user with passcode auth")
    func testCreateUserWithPasscode() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let user = try repository.createUser(
            email: "passcode@example.com",
            password: nil,
            passcode: "135792",
            fullName: "Jane Smith",
            authMethod: .passcode
        )

        #expect(user.email == "passcode@example.com")
        #expect(user.authMethod == "passcode")
        #expect(user.encryptedPasscodeHash != nil)
        #expect(user.encryptedPasswordHash == nil)
    }

    @Test("Create user with biometric auth")
    func testCreateUserWithBiometric() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let user = try repository.createUser(
            email: "biometric@example.com",
            password: nil,
            passcode: nil,
            fullName: "Bob Johnson",
            authMethod: .biometric
        )

        #expect(user.email == "biometric@example.com")
        #expect(user.authMethod == "biometric")
        #expect(user.encryptedPasswordHash == nil)
        #expect(user.encryptedPasscodeHash == nil)
    }

    @Test("Email is stored in lowercase")
    func testEmailLowercase() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let user = try repository.createUser(
            email: "MixedCase@Example.COM",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: "Test User",
            authMethod: .password
        )

        #expect(user.email == "mixedcase@example.com")
    }

    @Test("Full name is encrypted")
    func testFullNameEncrypted() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let fullName = "John Doe"
        let user = try repository.createUser(
            email: "test@example.com",
            password: "SecurePassword123!",
            passcode: nil,
            fullName: fullName,
            authMethod: .password
        )

        // Encrypted name should not contain plaintext
        if let encryptedName = user.encryptedFullName {
            let encryptedString = String(data: encryptedName, encoding: .utf8) ?? ""
            #expect(!encryptedString.contains(fullName))
        }

        // Should be able to decrypt
        let decryptedName = try repository.getDecryptedFullName(for: user)
        #expect(decryptedName == fullName)
    }

    // MARK: - Find User Tests

    @Test("Find user by email")
    func testFindUserByEmail() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        // Create user
        _ = try repository.createUser(
            email: "findme@example.com",
            password: "Password123!",
            passcode: nil,
            fullName: "Find Me",
            authMethod: .password
        )

        // Find user
        let foundUser = repository.findUser(by: "findme@example.com")
        #expect(foundUser != nil)
        #expect(foundUser?.email == "findme@example.com")
    }

    @Test("Find user by ID")
    func testFindUserById() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        // Create user
        let user = try repository.createUser(
            email: "findbyid@example.com",
            password: "Password123!",
            passcode: nil,
            fullName: "Find By ID",
            authMethod: .password
        )

        // Find by ID
        let foundUser = repository.findUser(by: user.id!)
        #expect(foundUser != nil)
        #expect(foundUser?.id == user.id)
    }

    @Test("Find non-existent user returns nil")
    func testFindNonExistentUser() {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let foundUser = repository.findUser(by: "nonexistent@example.com")
        #expect(foundUser == nil)
    }

    // MARK: - Authentication Tests

    @Test("Authenticate user with valid password")
    func testAuthenticateWithValidPassword() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let email = "auth@example.com"
        let password = "ValidPassword123!"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Auth User",
            authMethod: .password
        )

        // Authenticate
        let authenticatedUser = try repository.authenticateUser(
            email: email,
            credential: password,
            authMethod: .password
        )

        #expect(authenticatedUser.email == email)
        #expect(authenticatedUser.lastLoginAt != nil)
    }

    @Test("Authenticate user with valid passcode")
    func testAuthenticateWithValidPasscode() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let email = "passcode@example.com"
        let passcode = "135792"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: nil,
            passcode: passcode,
            fullName: "Passcode User",
            authMethod: .passcode
        )

        // Authenticate
        let authenticatedUser = try repository.authenticateUser(
            email: email,
            credential: passcode,
            authMethod: .passcode
        )

        #expect(authenticatedUser.email == email)
    }

    @Test("Reject invalid password")
    func testRejectInvalidPassword() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let email = "secure@example.com"
        let correctPassword = "CorrectPassword123!"
        let wrongPassword = "WrongPassword123!"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: correctPassword,
            passcode: nil,
            fullName: "Secure User",
            authMethod: .password
        )

        // Try to authenticate with wrong password
        #expect(throws: UserRepositoryError.invalidCredentials) {
            try repository.authenticateUser(
                email: email,
                credential: wrongPassword,
                authMethod: .password
            )
        }
    }

    @Test("Reject wrong auth method")
    func testRejectWrongAuthMethod() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let email = "method@example.com"
        let password = "Password123!"

        // Create user with password auth
        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Method User",
            authMethod: .password
        )

        // Try to authenticate with passcode method
        #expect(throws: UserRepositoryError.invalidAuthMethod) {
            try repository.authenticateUser(
                email: email,
                credential: password,
                authMethod: .passcode
            )
        }
    }

    @Test("Authenticate non-existent user fails")
    func testAuthenticateNonExistentUser() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        #expect(throws: UserRepositoryError.invalidCredentials) {
            try repository.authenticateUser(
                email: "nonexistent@example.com",
                credential: "Password123!",
                authMethod: .password
            )
        }
    }

    // MARK: - Email Registration Check

    @Test("Check if email is registered")
    func testIsEmailRegistered() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        let email = "registered@example.com"

        // Initially not registered
        #expect(repository.isEmailRegistered(email) == false)

        // Create user
        _ = try repository.createUser(
            email: email,
            password: "Password123!",
            passcode: nil,
            fullName: "Registered User",
            authMethod: .password
        )

        // Now registered
        #expect(repository.isEmailRegistered(email) == true)
    }

    // MARK: - Update User Tests

    @Test("Update user successfully")
    func testUpdateUser() throws {
        let context = createInMemoryContext()
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: AuditLogger(context: context)
        )

        // Create user
        let user = try repository.createUser(
            email: "update@example.com",
            password: "Password123!",
            passcode: nil,
            fullName: "Original Name",
            authMethod: .password
        )

        // Update account status
        user.accountStatus = "suspended"
        try repository.updateUser(user)

        // Verify update
        let updatedUser = repository.findUser(by: "update@example.com")
        #expect(updatedUser?.accountStatus == "suspended")
    }

    // MARK: - Audit Logging Tests

    @Test("Account creation is logged")
    func testAccountCreationLogged() throws {
        let context = createInMemoryContext()
        let auditLogger = AuditLogger(context: context)
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: auditLogger
        )

        // Create user
        let user = try repository.createUser(
            email: "logged@example.com",
            password: "Password123!",
            passcode: nil,
            fullName: "Logged User",
            authMethod: .password
        )

        // Check audit log
        let auditEvents = try auditLogger.fetchUserEvents(userId: user.id!)
        let accountCreatedEvents = auditEvents.filter {
            $0.entry.eventType == "account_created"
        }

        #expect(accountCreatedEvents.count >= 1)
    }

    @Test("Login success is logged")
    func testLoginSuccessLogged() throws {
        let context = createInMemoryContext()
        let auditLogger = AuditLogger(context: context)
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: auditLogger
        )

        let email = "loginlog@example.com"
        let password = "Password123!"

        // Create and authenticate user
        _ = try repository.createUser(
            email: email,
            password: password,
            passcode: nil,
            fullName: "Login Log User",
            authMethod: .password
        )

        let user = try repository.authenticateUser(
            email: email,
            credential: password,
            authMethod: .password
        )

        // Check audit log for login success
        let auditEvents = try auditLogger.fetchUserEvents(userId: user.id!)
        let loginEvents = auditEvents.filter {
            $0.entry.eventType == "login_success"
        }

        #expect(loginEvents.count >= 1)
    }

    @Test("Login failure is logged")
    func testLoginFailureLogged() throws {
        let context = createInMemoryContext()
        let auditLogger = AuditLogger(context: context)
        let repository = CoreDataUserRepository(
            context: context,
            encryptionManager: EncryptionManager.shared,
            passwordHasher: PasswordHasher.shared,
            auditLogger: auditLogger
        )

        let email = "faillog@example.com"

        // Create user
        _ = try repository.createUser(
            email: email,
            password: "CorrectPassword123!",
            passcode: nil,
            fullName: "Fail Log User",
            authMethod: .password
        )

        // Try to authenticate with wrong password
        try? repository.authenticateUser(
            email: email,
            credential: "WrongPassword123!",
            authMethod: .password
        )

        // Check audit log for login failure
        let auditEvents = try auditLogger.fetchEvents(eventType: .loginFailure)
        #expect(auditEvents.count >= 1)
    }
}
