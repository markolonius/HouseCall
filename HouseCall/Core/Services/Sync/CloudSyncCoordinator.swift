//
//  CloudSyncCoordinator.swift
//  HouseCall
//
//  Phase 6.3 — Coordinates the Core API sync loop for the chat flow.
//
//  Responsibilities:
//  - POST new user messages to the Core API; transition syncState pending→synced.
//  - Subscribe to SyncClient.eventPublisher and handle recommendation.delivered.
//  - Fetch delivered recommendations, persist them as encrypted assistant
//    messages (syncState=synced), and publish RecommendationCardModel objects
//    for the UI.
//  - Replay pending messages on reconnect / app-foreground.
//  - Reconnect the WebSocket after a transport failure.
//
//  HIPAA guardrails:
//  - All message/recommendation content is encrypted at rest before Core Data
//    write; only non-PHI metadata (IDs, syncState strings) live in plain fields.
//  - serverId and syncState are non-PHI metadata; no PHI appears in logs.
//  - JWT is never logged; it is pulled from Keychain only inside SyncClient.
//

import Foundation
import Combine
import CoreData
import UIKit

// MARK: - RecommendationCardModel

/// A value type that carries everything a RecommendationCard needs to render.
/// Constructed from a RecommendationDTO after the recommendation is persisted
/// locally as an assistant message.
///
/// `payloadType` drives view dispatch:
///  - `"guidance"` → single text card (MVP)
///  - future types (prescription, lab_order, referral) add a new case without
///    touching CloudSyncCoordinator.
struct RecommendationCardModel: Identifiable, Equatable {
    let id: String                  // recommendation server ID (non-PHI)
    let conversationLocalId: UUID   // local conversation UUID for routing
    let payloadType: String         // e.g. "guidance"
    let finalContent: String        // decrypted text to render (already in Core Data)
    let messageLocalId: UUID        // local Message UUID (for scrolling/ID)
}

// MARK: - CloudSyncCoordinator

/// Main-actor coordinator that bridges the SyncClient ↔ Core Data ↔ UI.
///
/// One shared instance per app session.  Inject a custom `SyncClient` in tests.
@MainActor
final class CloudSyncCoordinator: ObservableObject {

    // MARK: - Published state

    /// Recommendation cards that arrived via WebSocket since this session started.
    /// ConversationViewModel observes this to inject cards into the message list.
    @Published private(set) var deliveredCards: [RecommendationCardModel] = []

    /// Incremented each time a `message.created` WS event causes new assistant
    /// messages to be persisted locally.  ConversationViewModel observes this to
    /// trigger a `loadMessages()` refresh so agent interview questions appear in
    /// the chat bubble list without requiring a manual pull-to-refresh.
    @Published private(set) var syncedMessageCount: Int = 0

    /// Non-nil while a pending-message replay is in progress.
    @Published private(set) var isReplaying: Bool = false

    /// Set when the Core API rejects the cached token (401). The app observes
    /// this to require re-login. Cloud sync is deactivated when it flips true;
    /// there is no automatic retry loop.
    @Published private(set) var requiresReauth: Bool = false

    // MARK: - Dependencies

    private let syncClient: SyncClient
    private let messageRepository: MessageRepositoryProtocol
    private let conversationRepository: ConversationRepositoryProtocol
    private let auditLogger: AuditLogger
    /// Managed object context used for sync-metadata updates and pending
    /// message fetches.  Defaults to the shared production view context;
    /// tests inject their own in-memory context.
    private let context: NSManagedObjectContext
    private var wsSubscription: AnyCancellable?
    private var foregroundSubscription: AnyCancellable?

    // MARK: - Init

    /// - Parameters:
    ///   - syncClient: Injected for tests; defaults to the app-level shared instance.
    ///   - messageRepository: Injected; defaults to the shared Core Data repository.
    ///   - conversationRepository: Injected; defaults to the shared Core Data repository.
    ///   - auditLogger: Injected; defaults to the shared logger.
    ///   - context: Managed object context for sync-metadata writes.
    ///     Defaults to the shared view context.
    init(
        syncClient: SyncClient,
        messageRepository: MessageRepositoryProtocol = CoreDataMessageRepository(),
        conversationRepository: ConversationRepositoryProtocol = CoreDataConversationRepository(),
        auditLogger: AuditLogger = .shared,
        context: NSManagedObjectContext = PersistenceController.shared.container.viewContext
    ) {
        self.syncClient = syncClient
        self.messageRepository = messageRepository
        self.conversationRepository = conversationRepository
        self.auditLogger = auditLogger
        self.context = context
    }

    // MARK: - Lifecycle

    /// Connect the WebSocket and subscribe to events.  Call once after login.
    func start() {
        syncClient.connectWebSocket()
        subscribeToWSEvents()
        subscribeToForegroundNotification()
    }

    /// Disconnect and clean up.  Call on logout.
    func stop() {
        syncClient.disconnectWebSocket()
        wsSubscription?.cancel()
        wsSubscription = nil
        foregroundSubscription?.cancel()
        foregroundSubscription = nil
    }

    /// Deactivates cloud sync after the Core API rejects the cached token (401).
    /// Stops the connection, clears the stale JWT so the activation gate will not
    /// re-arm with a dead token, and flips `requiresReauth` so the app prompts a
    /// fresh login. Idempotent and loop-free: once `requiresReauth` is set, no
    /// further work is done, so repeated 401s do not retry or re-trigger.
    private func handleUnauthorized() {
        guard !requiresReauth else { return }
        stop()
        try? KeychainManager.shared.delete(key: KeychainManager.Keys.coreAPIJWT)
        requiresReauth = true
    }

    // MARK: - Message send (called by AIConversationService)

    /// POST the user message to the Core API.
    ///
    /// Pre-condition: the message has already been saved to Core Data with
    /// `syncState = "pending"`.  This method updates the metadata fields only;
    /// it never touches `encryptedContent`.
    ///
    /// On `.offline` the method returns without throwing — the message stays
    /// `pending` for the next replay pass.  All other errors are propagated.
    func postMessage(
        localMessageId: UUID,
        conversationServerId: String,
        conversationLocalId: UUID
    ) async throws {
        // Fetch the local message to get the (decrypted) content for the POST body.
        guard let message = try messageRepository.fetchMessage(id: localMessageId) else {
            return
        }

        // Decrypt content only to pass in the POST body — it is never stored
        // back to Core Data in plaintext.
        let content: String
        do {
            content = try messageRepository.decryptMessageContent(message)
        } catch {
            // Cannot POST without content; mark failed.
            updateSyncState(messageId: localMessageId, syncState: "failed", serverId: nil)
            throw error
        }

        do {
            // Pass the local message UUID as the idempotency key.  The server
            // uses (tenant_id, conversation_id, idempotency_key) to deduplicate:
            // if the original POST reached the server but the 201 was lost in
            // transit, replay carries the same key and receives the original
            // server message ID (HTTP 200) instead of inserting a duplicate.
            // The iOS client treats both 200 and 201 as success and adopts the
            // returned serverId exactly as before.
            let dto = try await syncClient.sendMessage(
                conversationID: conversationServerId,
                content: content,
                idempotencyKey: localMessageId.uuidString
            )
            // Promote pending → synced and record the server-assigned ID.
            updateSyncState(
                messageId: localMessageId,
                syncState: "synced",
                serverId: dto.ID
            )

            try? auditLogger.log(
                event: .aiInteraction,
                userId: nil,
                details: AuditEventDetails(additionalInfo: [
                    "messageLocalId": localMessageId.uuidString,
                    "syncState": "synced"
                ])
            )
        } catch SyncError.unauthorized {
            // Cached token rejected — deactivate cloud sync and require re-login.
            // Leave the message pending; it replays after re-auth.
            handleUnauthorized()
        } catch SyncError.offline {
            // Transient: leave message pending so replay picks it up.
            // No state change, no rethrow.
        } catch SyncError.serverError(let code) where code >= 400 && code < 500 {
            // Client error (4xx) — permanent failure; mark as failed.
            updateSyncState(messageId: localMessageId, syncState: "failed", serverId: nil)
            throw SyncError.serverError(code)
        } catch {
            // Other errors (decode, etc.) — leave pending and rethrow.
            throw error
        }
    }

    // MARK: - Replay

    /// Scan Core Data for `pending` messages and re-POST them in timestamp order.
    ///
    /// Triggered on reconnect or app-foreground.  Uses the conversation's
    /// `serverId` to build the POST path; if a conversation has no `serverId`,
    /// it has never been synced and is skipped (a future slice can handle
    /// conversation creation).
    func replayPendingMessages() async {
        guard !isReplaying else { return }
        isReplaying = true
        defer { isReplaying = false }

        // Reconnect the WebSocket so we receive any queued events.
        syncClient.reconnectWebSocket()

        do {
            let pendingMessages = try fetchPendingMessages()
            for message in pendingMessages {
                guard
                    let localId = message.id,
                    let conversationId = message.conversationId
                else { continue }

                // Look up the server ID for this conversation.
                guard
                    let conversation = try? conversationRepository.fetchConversation(id: conversationId),
                    let conversationServerId = conversation.serverId,
                    !conversationServerId.isEmpty
                else { continue }

                // Attempt to re-POST; offline will silently leave pending again.
                try? await postMessage(
                    localMessageId: localId,
                    conversationServerId: conversationServerId,
                    conversationLocalId: conversationId
                )
            }
        } catch {
            // Log without PHI; replay will run again on next foreground.
            try? auditLogger.log(
                event: .aiInteractionFailed,
                userId: nil,
                details: AuditEventDetails(
                    errorMessage: "replay fetch failed",
                    additionalInfo: ["error": error.localizedDescription]
                )
            )
        }
    }

    // MARK: - WebSocket event handling

    private func subscribeToWSEvents() {
        wsSubscription = syncClient.eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                guard let self else { return }
                Task { @MainActor in
                    await self.handleWSEvent(event)
                }
            }
    }

    private func handleWSEvent(_ event: WSEvent) async {
        switch event.type {
        case "recommendation.delivered":
            guard let recId = event.data.recommendation_id else { return }
            await handleRecommendationDelivered(recommendationId: recId,
                                                conversationId: event.data.conversation_id)
        case "message.created":
            // The server persisted a new message (typically an agent interview
            // question) on the conversation.  Fetch the full message list and
            // upsert any assistant messages that are not yet present locally.
            guard let cidString = event.data.conversation_id else { return }
            await handleMessageCreated(conversationIdString: cidString)
        default:
            break
        }
    }

    private func handleRecommendationDelivered(
        recommendationId: String,
        conversationId: String?
    ) async {
        do {
            let dto = try await syncClient.getRecommendation(recommendationID: recommendationId)

            // Only process DELIVERED recommendations for the patient's own view.
            guard dto.State == "DELIVERED",
                  let finalContent = dto.FinalContent,
                  !finalContent.isEmpty else { return }

            // Resolve the local conversation UUID.
            // conversationId (from the WS event) takes precedence; fall back
            // to dto.ConversationID (non-optional String from the REST response).
            let cidString = conversationId ?? dto.ConversationID
            let localConversationId: UUID? = UUID(uuidString: cidString)

            guard let convLocalId = localConversationId else { return }

            // Look up the user ID so we can encrypt the content at rest.
            let userId: UUID
            do {
                userId = try messageRepository.getUserId(for: convLocalId)
            } catch {
                return
            }

            // Persist as an encrypted assistant message.
            let savedMessage = try messageRepository.createMessage(
                conversationId: convLocalId,
                role: .assistant,
                content: finalContent,
                streamingComplete: true
            )

            // Mark the new message as synced with its server recommendation ID.
            updateSyncState(
                messageId: savedMessage.id!,
                syncState: "synced",
                serverId: dto.ID
            )

            // Publish the card model to the UI.
            let card = RecommendationCardModel(
                id: dto.ID,
                conversationLocalId: convLocalId,
                payloadType: dto.PayloadType,
                finalContent: finalContent,
                messageLocalId: savedMessage.id!
            )
            deliveredCards.append(card)

            try? auditLogger.log(
                event: .aiInteraction,
                userId: userId,
                details: AuditEventDetails(additionalInfo: [
                    "event": "recommendation.delivered",
                    "recommendationId": dto.ID
                ])
            )
        } catch SyncError.unauthorized {
            // Cached token rejected — deactivate cloud sync, require re-login.
            handleUnauthorized()
        } catch SyncError.serverError(404) {
            // Recommendation not yet DELIVERED — server returned 404; ignore.
            return
        } catch {
            // Other errors: log without PHI, do not crash.
            try? auditLogger.log(
                event: .aiInteractionFailed,
                userId: nil,
                details: AuditEventDetails(
                    errorMessage: "recommendation delivery handling failed",
                    additionalInfo: ["recommendationId": recommendationId]
                )
            )
        }
    }

    /// Handles a `message.created` WebSocket push.
    ///
    /// Fetches all messages for the conversation from the server and persists
    /// any assistant-role messages that are not yet present locally.
    /// De-duplication is keyed on the server message ID stored in `serverId`,
    /// so replaying the event on reconnect is safe (no double-inserts).
    ///
    /// Only non-PHI metadata (IDs, syncState, role) is used in audit entries.
    private func handleMessageCreated(conversationIdString: String) async {
        guard let convLocalId = UUID(uuidString: conversationIdString) else { return }

        // Resolve the conversation's server ID — required to call listMessages.
        guard
            let conversation = try? conversationRepository.fetchConversation(id: convLocalId),
            let conversationServerId = conversation.serverId,
            !conversationServerId.isEmpty
        else { return }

        // Resolve the user ID for content encryption.
        let userId: UUID
        do {
            userId = try messageRepository.getUserId(for: convLocalId)
        } catch {
            return
        }

        do {
            let serverMessages = try await syncClient.listMessages(conversationID: conversationServerId)

            // Build the set of server message IDs already present locally so we
            // can skip messages that were already persisted (de-duplication for
            // reconnect / replay scenarios).
            let existingServerIds = fetchExistingServerIds(conversationId: convLocalId)

            var insertedCount = 0
            for dto in serverMessages {
                // Only insert assistant-role messages not yet in Core Data.
                guard dto.Role == "assistant",
                      !existingServerIds.contains(dto.ID) else { continue }

                let savedMessage = try messageRepository.createMessage(
                    conversationId: convLocalId,
                    role: .assistant,
                    content: dto.Content,
                    streamingComplete: true
                )

                // Mark synced with the server-assigned message ID.
                updateSyncState(
                    messageId: savedMessage.id!,
                    syncState: "synced",
                    serverId: dto.ID
                )

                insertedCount += 1

                // Audit with identifiers only — no content/PHI.
                try? auditLogger.log(
                    event: .messageReceived,
                    userId: userId,
                    details: AuditEventDetails(additionalInfo: [
                        "event": "message.created",
                        "messageServerId": dto.ID
                    ])
                )
            }

            if insertedCount > 0 {
                syncedMessageCount += insertedCount
            }

        } catch SyncError.unauthorized {
            // Cached token rejected — deactivate cloud sync, require re-login.
            handleUnauthorized()
        } catch SyncError.offline {
            // Transient; the event will be reprocessed on reconnect.
        } catch {
            // Log without PHI; do not crash.
            try? auditLogger.log(
                event: .aiInteractionFailed,
                userId: nil,
                details: AuditEventDetails(
                    errorMessage: "message.created handling failed",
                    additionalInfo: ["conversationId": conversationIdString]
                )
            )
        }
    }

    // MARK: - Foreground notification

    private func subscribeToForegroundNotification() {
        foregroundSubscription = NotificationCenter.default
            .publisher(for: UIApplication.willEnterForegroundNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.replayPendingMessages()
                }
            }
    }

    // MARK: - Core Data helpers

    /// Returns the set of server message IDs (`serverId`) already stored for
    /// the given conversation.  Used by `handleMessageCreated` to skip messages
    /// that were already persisted, preventing double-inserts on replay.
    private func fetchExistingServerIds(conversationId: UUID) -> Set<String> {
        let request: NSFetchRequest<Message> = Message.fetchRequest()
        request.predicate = NSPredicate(
            format: "conversationId == %@ AND serverId != nil",
            conversationId as CVarArg
        )
        let existing = (try? context.fetch(request)) ?? []
        return Set(existing.compactMap { $0.serverId })
    }

    private func fetchPendingMessages() throws -> [Message] {
        let request: NSFetchRequest<Message> = Message.fetchRequest()
        request.predicate = NSPredicate(format: "syncState == %@", "pending")
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
        return try context.fetch(request)
    }

    /// Updates `syncState` and optionally `serverId` on a Message without
    /// touching `encryptedContent`.  Best-effort; failures are discarded.
    private func updateSyncState(
        messageId: UUID,
        syncState: String,
        serverId: String?
    ) {
        let request: NSFetchRequest<Message> = Message.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", messageId as CVarArg)
        request.fetchLimit = 1
        guard let message = try? context.fetch(request).first else { return }
        message.syncState = syncState
        if let sid = serverId {
            message.serverId = sid
        }
        try? context.save()
    }
}

