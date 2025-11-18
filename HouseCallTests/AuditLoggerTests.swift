//
//  AuditLoggerTests.swift
//  HouseCallTests
//
//  Unit tests for HIPAA-compliant audit logging system
//

import Testing
import CoreData
@testable import HouseCall

@Suite("AuditLogger Tests")
struct AuditLoggerTests {

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

    // MARK: - Basic Logging Tests

    @Test("Log basic audit event")
    func testLogBasicEvent() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        let details = AuditEventDetails(message: "Test event")

        try logger.log(event: .loginSuccess, userId: userId, details: details)

        // Verify event was saved
        let fetchRequest: NSFetchRequest<AuditLogEntry> = AuditLogEntry.fetchRequest()
        let entries = try context.fetch(fetchRequest)

        #expect(entries.count == 1)
        #expect(entries[0].eventType == "login_success")
        #expect(entries[0].userId == userId)
        #expect(entries[0].encryptedDetails != nil)
    }

    @Test("Log event with simple message")
    func testLogEventWithMessage() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        try logger.log(event: .accountCreated, userId: userId, message: "Account created successfully")

        let results = try logger.fetchEvents(for: userId)
        #expect(results.count == 1)
        #expect(results[0].details.message == "Account created successfully")
    }

    @Test("Log event without user ID (system event)")
    func testLogSystemEvent() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let details = AuditEventDetails(message: "System startup")
        try logger.log(event: .securityAlertTampering, userId: nil, details: details)

        let fetchRequest: NSFetchRequest<AuditLogEntry> = AuditLogEntry.fetchRequest()
        let entries = try context.fetch(fetchRequest)

        #expect(entries.count == 1)
        #expect(entries[0].userId == nil)
    }

    // MARK: - Encryption Tests

    @Test("Event details are encrypted")
    func testEventDetailsEncryption() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        let sensitiveMessage = "Sensitive patient data accessed"
        let details = AuditEventDetails(message: sensitiveMessage)

        try logger.log(event: .dataAccessed, userId: userId, details: details)

        // Fetch raw entry from Core Data
        let fetchRequest: NSFetchRequest<AuditLogEntry> = AuditLogEntry.fetchRequest()
        let entries = try context.fetch(fetchRequest)

        #expect(entries.count == 1)

        // Verify the encrypted data doesn't contain plaintext
        if let encryptedData = entries[0].encryptedDetails {
            let encryptedString = String(data: encryptedData, encoding: .utf8) ?? ""
            #expect(!encryptedString.contains(sensitiveMessage))
        }
    }

    @Test("Decrypt event details correctly")
    func testEventDetailsDecryption() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        let originalMessage = "User logged in from new device"
        let details = AuditEventDetails(
            message: originalMessage,
            authMethod: "biometric"
        )

        try logger.log(event: .loginSuccess, userId: userId, details: details)

        // Fetch and decrypt
        let results = try logger.fetchEvents(for: userId)

        #expect(results.count == 1)
        #expect(results[0].details.message == originalMessage)
        #expect(results[0].details.authMethod == "biometric")
    }

    // MARK: - Convenience Method Tests

    @Test("Log login success")
    func testLogLoginSuccess() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        try logger.logLoginSuccess(userId: userId, authMethod: "password")

        let results = try logger.fetchEvents(for: userId, eventType: .loginSuccess)
        #expect(results.count == 1)
        #expect(results[0].details.authMethod == "password")
    }

    @Test("Log login failure")
    func testLogLoginFailure() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        try logger.logLoginFailure(
            email: "test@example.com",
            reason: "Invalid password",
            authMethod: "password"
        )

        let results = try logger.fetchEvents(eventType: .loginFailure)
        #expect(results.count == 1)
        #expect(results[0].details.errorMessage == "Invalid password")
        #expect(results[0].details.authMethod == "password")
    }

    @Test("Log account created")
    func testLogAccountCreated() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        try logger.logAccountCreated(userId: userId, authMethod: "biometric")

        let results = try logger.fetchEvents(for: userId, eventType: .accountCreated)
        #expect(results.count == 1)
        #expect(results[0].details.authMethod == "biometric")
    }

    @Test("Log session timeout")
    func testLogSessionTimeout() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        try logger.logSessionTimeout(userId: userId)

        let results = try logger.fetchEvents(for: userId, eventType: .sessionTimeout)
        #expect(results.count == 1)
        #expect(results[0].details.message == "User session timed out after inactivity")
    }

    @Test("Log biometric enrolled")
    func testLogBiometricEnrolled() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        try logger.logBiometricEnrolled(userId: userId, biometricType: "Face ID")

        let results = try logger.fetchEvents(for: userId, eventType: .biometricEnrolled)
        #expect(results.count == 1)
        #expect(results[0].details.authMethod == "Face ID")
    }

    // MARK: - Query Tests

    @Test("Fetch events for specific user")
    func testFetchUserEvents() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let user1 = UUID()
        let user2 = UUID()

        try logger.log(event: .loginSuccess, userId: user1, message: "User 1 login")
        try logger.log(event: .loginSuccess, userId: user2, message: "User 2 login")
        try logger.log(event: .logoutSuccess, userId: user1, message: "User 1 logout")

        let user1Events = try logger.fetchUserEvents(userId: user1)
        #expect(user1Events.count == 2)

        let user2Events = try logger.fetchUserEvents(userId: user2)
        #expect(user2Events.count == 1)
    }

    @Test("Fetch events by event type")
    func testFetchEventsByType() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()

        try logger.log(event: .loginSuccess, userId: userId, message: "Login")
        try logger.log(event: .loginFailure, userId: userId, message: "Failed login")
        try logger.log(event: .loginSuccess, userId: userId, message: "Another login")

        let successEvents = try logger.fetchEvents(eventType: .loginSuccess)
        #expect(successEvents.count == 2)

        let failureEvents = try logger.fetchEvents(eventType: .loginFailure)
        #expect(failureEvents.count == 1)
    }

    @Test("Fetch events by date range")
    func testFetchEventsByDateRange() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        let now = Date()
        let twoDaysAgo = Calendar.current.date(byAdding: .day, value: -2, to: now)!

        try logger.log(event: .loginSuccess, userId: userId, message: "Login today")

        // Fetch events from last 7 days
        let recentEvents = try logger.fetchRecentEvents(days: 7)
        #expect(recentEvents.count == 1)

        // Fetch events with specific date range
        let rangeEvents = try logger.fetchEvents(dateRange: twoDaysAgo...now)
        #expect(rangeEvents.count == 1)
    }

    @Test("Events are sorted chronologically")
    func testEventsSortedChronologically() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()

        try logger.log(event: .loginSuccess, userId: userId, message: "First")
        Thread.sleep(forTimeInterval: 0.01) // Small delay to ensure different timestamps
        try logger.log(event: .dataAccessed, userId: userId, message: "Second")
        Thread.sleep(forTimeInterval: 0.01)
        try logger.log(event: .logoutSuccess, userId: userId, message: "Third")

        let events = try logger.fetchEvents(for: userId)

        #expect(events.count == 3)
        #expect(events[0].details.message == "First")
        #expect(events[1].details.message == "Second")
        #expect(events[2].details.message == "Third")

        // Verify timestamps are in order
        #expect(events[0].entry.timestamp! < events[1].entry.timestamp!)
        #expect(events[1].entry.timestamp! < events[2].entry.timestamp!)
    }

    @Test("Count events")
    func testCountEvents() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()

        try logger.log(event: .loginSuccess, userId: userId, message: "Login 1")
        try logger.log(event: .loginSuccess, userId: userId, message: "Login 2")
        try logger.log(event: .loginFailure, userId: userId, message: "Failed")

        let totalCount = try logger.countEvents(for: userId)
        #expect(totalCount == 3)

        let successCount = try logger.countEvents(for: userId, eventType: .loginSuccess)
        #expect(successCount == 2)

        let failureCount = try logger.countEvents(for: userId, eventType: .loginFailure)
        #expect(failureCount == 1)
    }

    // MARK: - Device ID Tests

    @Test("Device ID is persistent")
    func testDeviceIdPersistence() throws {
        let context1 = createInMemoryContext()
        let logger1 = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context1
        )

        let userId = UUID()
        try logger1.log(event: .loginSuccess, userId: userId, message: "First log")

        let fetchRequest1: NSFetchRequest<AuditLogEntry> = AuditLogEntry.fetchRequest()
        let entries1 = try context1.fetch(fetchRequest1)
        let deviceId1 = entries1[0].deviceId

        // Create another logger instance (should use same device ID from UserDefaults)
        let context2 = createInMemoryContext()
        let logger2 = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context2
        )

        try logger2.log(event: .loginSuccess, userId: userId, message: "Second log")

        let fetchRequest2: NSFetchRequest<AuditLogEntry> = AuditLogEntry.fetchRequest()
        let entries2 = try context2.fetch(fetchRequest2)
        let deviceId2 = entries2[0].deviceId

        #expect(deviceId1 == deviceId2)
    }

    // MARK: - HIPAA Compliance Tests

    @Test("All required event types are defined")
    func testRequiredEventTypes() {
        // Verify all HIPAA-required events are available
        #expect(AuditEventType.accountCreated.rawValue == "account_created")
        #expect(AuditEventType.loginSuccess.rawValue == "login_success")
        #expect(AuditEventType.loginFailure.rawValue == "login_failure")
        #expect(AuditEventType.biometricEnrolled.rawValue == "biometric_enrolled")
        #expect(AuditEventType.sessionTimeout.rawValue == "session_timeout")
        #expect(AuditEventType.securityAlertTampering.rawValue == "security_alert_tampering")
    }

    @Test("Millisecond precision timestamps")
    func testMillisecondPrecision() throws {
        let context = createInMemoryContext()
        let logger = AuditLogger(
            encryptionManager: EncryptionManager.shared,
            context: context
        )

        let userId = UUID()
        let beforeLog = Date()
        try logger.log(event: .loginSuccess, userId: userId, message: "Test")
        let afterLog = Date()

        let results = try logger.fetchEvents(for: userId)
        let loggedTimestamp = results[0].entry.timestamp!

        // Verify timestamp is within expected range (millisecond precision)
        #expect(loggedTimestamp >= beforeLog)
        #expect(loggedTimestamp <= afterLog)
    }
}
