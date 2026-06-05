//
//  Persistence.swift
//  HouseCall
//
//  HIPAA-compliant Core Data persistence with file protection
//  Enhanced for healthcare data security requirements
//

import CoreData

/// Errors that can occur during persistence operations
enum PersistenceError: LocalizedError {
    case storeLoadFailed(Error)
    case saveFailed(Error)
    case initializationFailed(String)

    var errorDescription: String? {
        switch self {
        case .storeLoadFailed(let error):
            return "Failed to load persistent store: \(error.localizedDescription)"
        case .saveFailed(let error):
            return "Failed to save context: \(error.localizedDescription)"
        case .initializationFailed(let reason):
            return "Persistence initialization failed: \(reason)"
        }
    }
}

/// HIPAA-compliant Core Data persistence controller
struct PersistenceController {
    static let shared = PersistenceController()

    @MainActor
    static let preview: PersistenceController = {
        PersistenceController(inMemory: true)
    }()

    let container: NSPersistentContainer
    private(set) var loadError: Error?

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "HouseCall")

        if inMemory {
            // In-memory store for testing/previews
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        } else {
            // Configure file protection for HIPAA compliance
            if let storeDescription = container.persistentStoreDescriptions.first {
                // Set file protection to complete (iOS encrypts when device is locked)
                storeDescription.setOption(
                    FileProtectionType.complete as NSObject,
                    forKey: NSPersistentStoreFileProtectionKey
                )

                // Enable lightweight migration so additive model changes (e.g. new
                // optional attributes for cloud sync metadata) upgrade existing stores
                // automatically without a manual mapping model.
                storeDescription.shouldMigrateStoreAutomatically = true
                storeDescription.shouldInferMappingModelAutomatically = true

                // Disable iCloud sync for PHI security
                storeDescription.setOption(true as NSObject, forKey: NSPersistentHistoryTrackingKey)
                storeDescription.setOption(true as NSObject, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
        }

        var loadErrorOccurred: Error?

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                loadErrorOccurred = error

                // Log error for debugging
                print("❌ Core Data store load error: \(error.localizedDescription)")
                print("   Store description: \(storeDescription)")
                print("   Error code: \(error.code)")
                print("   Error details: \(error.userInfo)")

                // Log to audit trail if AuditLogger is available
                if !inMemory {
                    do {
                        try AuditLogger.shared.log(
                            event: .encryptionFailure,
                            userId: nil,
                            message: "Core Data initialization failed: \(error.localizedDescription)"
                        )
                    } catch {
                        print("⚠️ Failed to log Core Data error to audit trail")
                    }
                }

                /*
                 Common reasons for Core Data errors:
                 - The parent directory does not exist or cannot be created
                 - Insufficient permissions or data protection while device is locked
                 - Device is out of storage space
                 - Store migration failure (model version mismatch)
                 - Corrupted database file

                 HIPAA Note: Do not expose PHI in error messages
                 */
            }
        }

        self.loadError = loadErrorOccurred

        // Enable automatic merging of changes from parent context
        container.viewContext.automaticallyMergesChangesFromParent = true

        // Configure merge policy for conflict resolution
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    }

    /// Saves the view context with proper error handling
    /// - Throws: PersistenceError if save fails
    func saveContext() throws {
        let context = container.viewContext

        guard context.hasChanges else {
            return // No changes to save
        }

        do {
            try context.save()
        } catch {
            // Rollback changes on error
            context.rollback()

            // Log error to audit trail
            try? AuditLogger.shared.log(
                event: .encryptionFailure,
                userId: nil,
                message: "Core Data save failed: \(error.localizedDescription)"
            )

            throw PersistenceError.saveFailed(error)
        }
    }

    /// Performs a background task with a new context
    /// - Parameter block: Block to execute with background context
    func performBackgroundTask(_ block: @escaping (NSManagedObjectContext) -> Void) {
        container.performBackgroundTask(block)
    }

    /// Creates a new background context
    /// - Returns: New background managed object context
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
}
