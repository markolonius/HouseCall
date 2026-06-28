//
//  SyncClient.swift
//  HouseCall
//
//  REST + WebSocket client for the Core API (Phase 6.2).
//
//  Responsibilities:
//  - Authenticate requests with the Core API JWT pulled from Keychain.
//  - POST patient messages to /api/conversations/{id}/messages.
//  - GET conversations and messages for initial state load.
//  - GET individual DELIVERED recommendations.
//  - Maintain a WebSocket connection to /ws?token=<jwt> and surface
//    incoming events (recommendation.delivered, queue.updated) via a
//    Combine publisher.  No Core Data writes happen here; that is 6.3.
//
//  HIPAA guardrails:
//  - The JWT is pulled from Keychain only; never from UserDefaults.
//  - The JWT and Authorization header are never logged.
//  - No PHI (message content, names) appears in error descriptions or logs.
//  - TLS is required for any non-localhost base URL.
//

import Foundation
import Combine

// MARK: - Errors

/// Typed errors for SyncClient callers.  Each case is distinguishable so
/// AIConversationService (6.3) can keep a message `pending` and replay.
enum SyncError: LocalizedError, Equatable {
    /// The server returned 401 — the JWT is missing or expired.
    case unauthorized
    /// The device is offline or the transport layer failed.
    case offline(String)
    /// The response body could not be decoded into the expected DTO.
    case decodeFailed(String)
    /// The server returned a non-2xx status other than 401.
    case serverError(Int)
    /// A non-localhost base URL was provided without HTTPS.
    case insecureBaseURL

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Session expired. Please log in again."
        case .offline:
            // The associated reason value is intentionally excluded from the
            // user-visible description — it may originate from system error
            // messages that could inadvertently carry sensitive context.
            return "Network unavailable. Check your connection and try again."
        case .decodeFailed:
            // The associated context value is intentionally excluded from the
            // user-visible description to avoid leaking internal type details.
            return "Response decode error. Please try again."
        case .serverError(let code):
            return "Server error (\(code))."
        case .insecureBaseURL:
            return "Non-localhost base URLs must use https://."
        }
    }

    static func == (lhs: SyncError, rhs: SyncError) -> Bool {
        switch (lhs, rhs) {
        case (.unauthorized, .unauthorized): return true
        case (.offline(let a), .offline(let b)): return a == b
        case (.decodeFailed(let a), .decodeFailed(let b)): return a == b
        case (.serverError(let a), .serverError(let b)): return a == b
        case (.insecureBaseURL, .insecureBaseURL): return true
        default: return false
        }
    }
}

// MARK: - Response DTOs
//
// Field names mirror the Go struct field names exactly.  The backend
// serialises store.Conversation / store.Message / store.Recommendation
// with no json tags, so Go's default encoder uses the struct field names
// as-is (capitalised).

struct ConversationDTO: Codable {
    let ID: String
    let TenantID: String
    let PatientID: String
    let Title: String
    let CreatedAt: String
    let UpdatedAt: String
}

struct MessageDTO: Codable {
    let ID: String
    let TenantID: String
    let ConversationID: String
    let Role: String
    let Content: String
    let CreatedAt: String
}

struct RecommendationDTO: Codable {
    let ID: String
    let TenantID: String
    let ConversationID: String
    let PatientID: String
    let State: String
    let PayloadType: String
    /// Raw JSONB bytes from the backend (e.g. `{"text":"…"}` for guidance).
    let Payload: Data?
    let DraftContent: String
    let FinalContent: String?
    let ReviewedBy: String?
    let ReviewedAt: String?
    let CreatedAt: String
}

// MARK: - WebSocket event DTOs

/// Top-level wrapper for all WebSocket push events.
struct WSEvent: Codable {
    let type: String
    let data: WSEventData
}

/// Payload carried by WebSocket push events.
/// All fields are optional; a given event type populates only the relevant subset.
struct WSEventData: Codable {
    let recommendation_id: String?
    let conversation_id: String?
    /// Server message ID carried by `message.created` events.
    /// Defaults to `nil` so existing callers that only supply the first two
    /// fields continue to compile without changes.
    var message_id: String? = nil
}

// MARK: - SyncClient

/// Dedicated REST + WebSocket client for the HouseCall Core API.
///
/// Inject a custom `URLSession` and `baseURL` in tests to avoid live
/// network calls (see `SyncClientTests`).
final class SyncClient {

    // MARK: - Dependencies

    private let baseURL: URL
    private let session: URLSession
    private let keychainManager: KeychainManager

    // MARK: - WebSocket

    private var wsTask: URLSessionWebSocketTask?
    private var wsReconnectTask: Task<Void, Never>?

    /// Emits decoded WebSocket events.  Subscribers receive events on an
    /// arbitrary thread; UI work must be dispatched to the main actor.
    let eventPublisher = PassthroughSubject<WSEvent, Never>()

    // MARK: - Initialisation

    /// - Parameters:
    ///   - baseURL: Core API host.  Default: `http://localhost:8080`.
    ///     Any non-localhost URL **must** use `https://`.
    ///   - session: URLSession to use for requests.  Defaults to a fresh
    ///     ephemeral session with no caching (suitable for PHI data).
    ///   - keychainManager: Keychain store that holds the Core API JWT.
    init(
        baseURL: URL = URL(string: "http://localhost:8080")!,
        session: URLSession? = nil,
        keychainManager: KeychainManager = .shared
    ) throws {
        // Enforce TLS for any non-localhost target.
        let host = baseURL.host ?? ""
        let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if !isLocalhost && baseURL.scheme != "https" {
            throw SyncError.insecureBaseURL
        }

        self.baseURL = baseURL
        self.keychainManager = keychainManager

        if let provided = session {
            self.session = provided
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - JWT access

    /// Returns the Core API JWT from Keychain.
    ///
    /// Never logs or exposes the token value.
    private func jwt() throws -> String {
        guard let token = try keychainManager.get(key: KeychainManager.Keys.coreAPIJWT) else {
            throw SyncError.unauthorized
        }
        guard !token.isEmpty else {
            throw SyncError.unauthorized
        }
        return token
    }

    // MARK: - Request builder

    private func authorisedRequest(
        method: String,
        path: String,
        body: Data? = nil
    ) throws -> URLRequest {
        let token = try jwt()
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SyncError.offline("invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        // JWT is set here; it must not be logged.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body = body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    // MARK: - Response handling

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError {
            throw SyncError.offline(urlError.localizedDescription)
        } catch {
            throw SyncError.offline(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw SyncError.offline("non-HTTP response")
        }

        if http.statusCode == 401 {
            throw SyncError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.serverError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let decodeError {
            throw SyncError.decodeFailed(decodeError.localizedDescription)
        }
    }

    // MARK: - REST API

    /// List all conversations for the authenticated patient.
    ///
    /// Maps to `GET /api/conversations`.
    func listConversations() async throws -> [ConversationDTO] {
        let request = try authorisedRequest(method: "GET", path: "/api/conversations")
        return try await perform(request)
    }

    /// List messages for a conversation.
    ///
    /// Maps to `GET /api/conversations/{id}/messages`.
    func listMessages(conversationID: String) async throws -> [MessageDTO] {
        let request = try authorisedRequest(
            method: "GET",
            path: "/api/conversations/\(conversationID)/messages"
        )
        return try await perform(request)
    }

    /// Send a patient message and receive the persisted message back.
    ///
    /// Maps to `POST /api/conversations/{id}/messages`.
    /// Returns the `MessageDTO` with the server-assigned `ID` (used as
    /// `serverId` in the local Core Data row).
    ///
    /// - Parameters:
    ///   - conversationID: Server-assigned conversation UUID string.
    ///   - content: Decrypted message text (never stored back to Core Data here).
    ///   - idempotencyKey: The local Core Data message UUID string.  When
    ///     provided, the server deduplicates: a second POST with the same key
    ///     for the same tenant + conversation returns the existing message
    ///     (HTTP 200) instead of inserting a duplicate (HTTP 201).  Both
    ///     status codes are treated as success by `perform(_:)` and the
    ///     returned `MessageDTO.ID` is used as `serverId` either way.  Pass
    ///     `nil` only for legacy / non-replay paths where no local UUID exists.
    func sendMessage(
        conversationID: String,
        content: String,
        idempotencyKey: String? = nil
    ) async throws -> MessageDTO {
        // Build the JSON body.  idempotency_key is omitted when nil so legacy
        // callers that do not pass a key send exactly {"content": "..."}.
        var bodyDict: [String: String] = ["content": content]
        if let key = idempotencyKey {
            bodyDict["idempotency_key"] = key
        }
        let payload = try JSONEncoder().encode(bodyDict)
        let request = try authorisedRequest(
            method: "POST",
            path: "/api/conversations/\(conversationID)/messages",
            body: payload
        )
        return try await perform(request)
    }

    /// Fetch a single DELIVERED recommendation.
    ///
    /// Maps to `GET /api/recommendations/{id}`.
    /// The backend returns 404 if the recommendation is not yet DELIVERED
    /// for this patient; callers receive `SyncError.serverError(404)`.
    func getRecommendation(recommendationID: String) async throws -> RecommendationDTO {
        let request = try authorisedRequest(
            method: "GET",
            path: "/api/recommendations/\(recommendationID)"
        )
        return try await perform(request)
    }

    // MARK: - WebSocket

    /// Connect the WebSocket listener.
    ///
    /// The token is appended as `?token=<jwt>` per the backend spec
    /// (`ws.go`): mobile clients cannot set Upgrade headers, so the
    /// server validates the JWT from the query parameter.
    ///
    /// Call `disconnectWebSocket()` before deinit or on logout.
    func connectWebSocket() {
        do {
            let token = try jwt()
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
            components.path = "/ws"
            components.queryItems = [URLQueryItem(name: "token", value: token)]
            // For ws:// upgrade from http:// base URL, replace scheme.
            if components.scheme == "http" { components.scheme = "ws" }
            if components.scheme == "https" { components.scheme = "wss" }
            guard let wsURL = components.url else { return }

            wsTask = session.webSocketTask(with: wsURL)
            wsTask?.resume()
            receiveNextMessage()
        } catch {
            // JWT unavailable — do not attempt to connect.
        }
    }

    /// Disconnect the WebSocket cleanly.
    func disconnectWebSocket() {
        wsReconnectTask?.cancel()
        wsReconnectTask = nil
        wsTask?.cancel(with: .normalClosure, reason: nil)
        wsTask = nil
    }

    /// Public re-entry point so 6.3 can trigger reconnect after a replay
    /// pass restores connectivity.
    func reconnectWebSocket() {
        disconnectWebSocket()
        connectWebSocket()
    }

    // MARK: - WebSocket receive loop

    private func receiveNextMessage() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleWSMessage(message)
                self.receiveNextMessage()
            case .failure:
                // Transport error; tear down and let the caller reconnect.
                self.wsTask = nil
            }
        }
    }

    private func handleWSMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let encoded = text.data(using: .utf8) else { return }
            data = encoded
        case .data(let bytes):
            data = bytes
        @unknown default:
            return
        }

        // Decode strictly — unknown types are silently dropped; no crash,
        // no PHI is emitted to logs.
        guard let event = try? JSONDecoder().decode(WSEvent.self, from: data) else {
            return
        }
        eventPublisher.send(event)
    }
}
