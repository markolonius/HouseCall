//
//  AuditLogger.swift
//  HouseCall
//
//  HIPAA-Compliant Audit Logging System
//  Implements audit trail requirements per 45 CFR § 164.312(b)
//

import Foundation
import CoreData

/// Types of audit events that must be logged for HIPAA compliance
enum AuditEventType: String, Codable {
    // Account Management Events
    case accountCreated = "account_created"
    case accountUpdated = "account_updated"
    case accountDeleted = "account_deleted"

    // Authentication Events
    case loginSuccess = "login_success"
    case loginFailure = "login_failure"
    case logoutSuccess = "logout_success"

    // Biometric Events
    case biometricEnrolled = "biometric_enrolled"
    case biometricDeclined = "biometric_declined"
    case biometricAuthSuccess = "biometric_auth_success"
    case biometricAuthFailure = "biometric_auth_failure"

    // Session Events
    case sessionCreated = "session_created"
    case sessionTimeout = "session_timeout"
    case sessionInvalidated = "session_invalidated"

    // Security Events
    case securityAlertTampering = "security_alert_tampering"
    case encryptionFailure = "encryption_failure"
    case decryptionFailure = "decryption_failure"
    case unauthorizedAccess = "unauthorized_access"

    // Password/Passcode Events
    case passwordChanged = "password_changed"
    case passcodeChanged = "passcode_changed"
    case passwordResetRequested = "password_reset_requested"

    // Data Access Events (for future PHI tracking)
    case dataAccessed = "data_accessed"
    case dataModified = "data_modified"
    case dataDeleted = "data_deleted"

    // Conversation Events
    case conversationCreated = "conversation_created"
    case conversationAccessed = "conversation_accessed"
    case conversationDeleted = "conversation_deleted"
    case conversationProviderSwitched = "conversation_provider_switched"

    // Message Events
    case messageCreated = "message_created"
    case messageSent = "message_sent"
    case messageReceived = "message_received"

    // AI Interaction Events
    case aiInteraction = "ai_interaction"
    case aiInteractionFailed = "ai_interaction_failed"
    case aiStreamingStarted = "ai_streaming_started"
    case aiStreamingCompleted = "ai_streaming_completed"
    case aiStreamingInterrupted = "ai_streaming_interrupted"
}

/// Details that can be included with audit events
struct AuditEventDetails: Codable {
    var message: String?
    var errorCode: String?
    var errorMessage: String?
    var ipAddress: String?
    var authMethod: String?
    var resourceId: String?
    var additionalInfo: [String: String]?

    init(message: String? = nil,
         errorCode: String? = nil,
         errorMessage: String? = nil,
         ipAddress: String? = nil,
         authMethod: String? = nil,
         resourceId: String? = nil,
         additionalInfo: [String: String]? = nil) {
        self.message = message
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.ipAddress = ipAddress
        self.authMethod = authMethod
        self.resourceId = resourceId
        self.additionalInfo = additionalInfo
    }
}

/// Errors that can occur during audit logging
enum AuditLogError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case saveFailed(Error)
    case fetchFailed(Error)
    case invalidData
    case deviceIdGenerationFailed

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "Failed to encrypt audit event details"
        case .decryptionFailed:
            return "Failed to decrypt audit event details"
        case .saveFailed(let error):
            return "Failed to save audit log entry: \(error.localizedDescription)"
        case .fetchFailed(let error):
            return "Failed to fetch audit log entries: \(error.localizedDescription)"
        case .invalidData:
            return "Invalid audit log data format"
        case .deviceIdGenerationFailed:
            return "Failed to generate or retrieve device identifier"
        }
    }
}

/// HIPAA-compliant audit logging system
/// Logs all security-relevant events with encrypted details
class AuditLogger {
    static let shared = AuditLogger()

    private let encryptionManager: EncryptionManager
    private let context: NSManagedObjectContext
    private let deviceId: String

    // System user ID for events that don't have a specific user
    private let systemUserId = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    init(
        encryptionManager: EncryptionManager = .shared,
        context: NSManagedObjectContext = PersistenceController.shared.container.viewContext
    ) {
        self.encryptionManager = encryptionManager
        self.context = context

        // Get or generate persistent device identifier
        if let existingDeviceId = UserDefaults.standard.string(forKey: "AuditLogDeviceId") {
            self.deviceId = existingDeviceId
        } else {
            let newDeviceId = UUID().uuidString
            UserDefaults.standard.set(newDeviceId, forKey: "AuditLogDeviceId")
            self.deviceId = newDeviceId
        }
    }

    // MARK: - Logging Methods

    /// Logs an audit event with encrypted details
    /// - Parameters:
    ///   - event: The type of event being logged
    ///   - userId: The user ID associated with the event (optional)
    ///   - details: Additional details about the event
    /// - Throws: AuditLogError if logging fails
    func log(
        event: AuditEventType,
        userId: UUID? = nil,
        details: AuditEventDetails
    ) throws {
        // Create audit log entry entity
        let entry = AuditLogEntry(context: context)
        entry.id = UUID()
        entry.timestamp = Date() // Millisecond precision timestamp
        entry.eventType = event.rawValue
        entry.userId = userId
        entry.deviceId = deviceId

        // Encrypt event details
        let detailsData: Data
        do {
            detailsData = try JSONEncoder().encode(details)
        } catch {
            throw AuditLogError.invalidData
        }

        // Use system user ID for encryption if no specific user
        let encryptionUserId = userId ?? systemUserId

        do {
            entry.encryptedDetails = try encryptionManager.encrypt(data: detailsData, for: encryptionUserId)
        } catch {
            throw AuditLogError.encryptionFailed
        }

        // Save to Core Data
        do {
            try context.save()
        } catch {
            throw AuditLogError.saveFailed(error)
        }
    }

    /// Convenience method to log events with a simple message
    /// - Parameters:
    ///   - event: The type of event being logged
    ///   - userId: The user ID associated with the event (optional)
    ///   - message: A simple message describing the event
    func log(event: AuditEventType, userId: UUID? = nil, message: String) throws {
        let details = AuditEventDetails(message: message)
        try log(event: event, userId: userId, details: details)
    }

    /// Logs a login success event
    func logLoginSuccess(userId: UUID, authMethod: String) throws {
        let details = AuditEventDetails(
            message: "User logged in successfully",
            authMethod: authMethod
        )
        try log(event: .loginSuccess, userId: userId, details: details)
    }

    /// Logs a login failure event
    func logLoginFailure(email: String, reason: String, authMethod: String) throws {
        let details = AuditEventDetails(
            message: "Login attempt failed",
            errorMessage: reason,
            authMethod: authMethod,
            additionalInfo: ["email": email]
        )
        try log(event: .loginFailure, userId: nil, details: details)
    }

    /// Logs an account creation event
    func logAccountCreated(userId: UUID, authMethod: String) throws {
        let details = AuditEventDetails(
            message: "New user account created",
            authMethod: authMethod
        )
        try log(event: .accountCreated, userId: userId, details: details)
    }

    /// Logs a session timeout event
    func logSessionTimeout(userId: UUID) throws {
        let details = AuditEventDetails(
            message: "User session timed out after inactivity"
        )
        try log(event: .sessionTimeout, userId: userId, details: details)
    }

    /// Logs a security tampering alert
    func logSecurityTampering(userId: UUID?, reason: String) throws {
        let details = AuditEventDetails(
            message: "Security tampering detected",
            errorMessage: reason
        )
        try log(event: .securityAlertTampering, userId: userId, details: details)
    }

    /// Logs a biometric enrollment event
    func logBiometricEnrolled(userId: UUID, biometricType: String) throws {
        let details = AuditEventDetails(
            message: "Biometric authentication enrolled",
            authMethod: biometricType
        )
        try log(event: .biometricEnrolled, userId: userId, details: details)
    }

    // MARK: - Query Methods

    /// Fetches audit log entries with optional filtering
    /// - Parameters:
    ///   - userId: Filter by user ID (optional)
    ///   - eventType: Filter by event type (optional)
    ///   - dateRange: Filter by date range (optional)
    /// - Returns: Array of tuples containing the entry and decrypted details
    /// - Throws: AuditLogError if fetch or decryption fails
    func fetchEvents(
        for userId: UUID? = nil,
        eventType: AuditEventType? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> [(entry: AuditLogEntry, details: AuditEventDetails)] {
        // Build fetch request
        let fetchRequest: NSFetchRequest<AuditLogEntry> = AuditLogEntry.fetchRequest()
        var predicates: [NSPredicate] = []

        // Add userId filter if provided
        if let userId = userId {
            predicates.append(NSPredicate(format: "userId == %@", userId as CVarArg))
        }

        // Add eventType filter if provided
        if let eventType = eventType {
            predicates.append(NSPredicate(format: "eventType == %@", eventType.rawValue))
        }

        // Add date range filter if provided
        if let dateRange = dateRange {
            predicates.append(NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@",
                dateRange.lowerBound as NSDate,
                dateRange.upperBound as NSDate
            ))
        }

        // Combine predicates
        if !predicates.isEmpty {
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        // Sort by timestamp (chronological order)
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]

        // Execute fetch
        let entries: [AuditLogEntry]
        do {
            entries = try context.fetch(fetchRequest)
        } catch {
            throw AuditLogError.fetchFailed(error)
        }

        // Decrypt details for each entry
        var results: [(entry: AuditLogEntry, details: AuditEventDetails)] = []
        for entry in entries {
            guard let encryptedDetails = entry.encryptedDetails else {
                throw AuditLogError.invalidData
            }

            // Use entry's userId or system user ID for decryption
            let decryptionUserId = entry.userId ?? systemUserId

            do {
                let decryptedData = try encryptionManager.decrypt(
                    encryptedData: encryptedDetails,
                    for: decryptionUserId
                )
                let details = try JSONDecoder().decode(AuditEventDetails.self, from: decryptedData)
                results.append((entry: entry, details: details))
            } catch {
                throw AuditLogError.decryptionFailed
            }
        }

        return results
    }

    /// Fetches all audit events for a specific user
    func fetchUserEvents(userId: UUID) throws -> [(entry: AuditLogEntry, details: AuditEventDetails)] {
        return try fetchEvents(for: userId)
    }

    /// Fetches recent audit events (last N days)
    func fetchRecentEvents(days: Int = 7) throws -> [(entry: AuditLogEntry, details: AuditEventDetails)] {
        let endDate = Date()
        guard let startDate = Calendar.current.date(byAdding: .day, value: -days, to: endDate) else {
            throw AuditLogError.invalidData
        }
        return try fetchEvents(dateRange: startDate...endDate)
    }

    /// Gets a count of audit events matching criteria
    func countEvents(
        for userId: UUID? = nil,
        eventType: AuditEventType? = nil,
        dateRange: ClosedRange<Date>? = nil
    ) throws -> Int {
        let fetchRequest: NSFetchRequest<AuditLogEntry> = AuditLogEntry.fetchRequest()
        var predicates: [NSPredicate] = []

        if let userId = userId {
            predicates.append(NSPredicate(format: "userId == %@", userId as CVarArg))
        }

        if let eventType = eventType {
            predicates.append(NSPredicate(format: "eventType == %@", eventType.rawValue))
        }

        if let dateRange = dateRange {
            predicates.append(NSPredicate(
                format: "timestamp >= %@ AND timestamp <= %@",
                dateRange.lowerBound as NSDate,
                dateRange.upperBound as NSDate
            ))
        }

        if !predicates.isEmpty {
            fetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }

        do {
            return try context.count(for: fetchRequest)
        } catch {
            throw AuditLogError.fetchFailed(error)
        }
    }
}
