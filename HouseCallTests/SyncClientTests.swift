//
//  SyncClientTests.swift
//  HouseCallTests
//
//  Unit tests for SyncClient (Phase 6.2).
//
//  All network calls are intercepted by SyncMockURLProtocol — no live
//  network access.  Tests follow the same Swift Testing (@Suite / @Test /
//  #expect) style used across HouseCallTests.
//
//  Parallel-safety: each test creates a unique session identified by a
//  UUID stored as a custom header in httpAdditionalHeaders.  The handler
//  registry is keyed by (sessionID, path), so parallel test workers never
//  interfere with each other's stubs.
//

import Testing
import Foundation
import Combine
@testable import HouseCall

// MARK: - SyncMockURLProtocol

/// Thread-safe URLProtocol stub.
///
/// Handlers are registered per sessionID + URL path.  The session ID is
/// injected via `X-Test-Session-ID` in `httpAdditionalHeaders` when the
/// URLSession is created; the protocol reads it back on every request.
final class SyncMockURLProtocol: URLProtocol {

    private struct Key: Hashable {
        let sessionID: String
        let path: String
    }

    private static let lock = NSLock()
    // Registry: (sessionID, path) -> handler
    private static var handlers: [Key: (URLRequest) -> (Data, HTTPURLResponse)] = [:]
    // Captured requests: (sessionID, request)
    private static var captured: [(String, URLRequest)] = []

    // MARK: Registration

    static func register(
        sessionID: String,
        path: String,
        handler: @escaping (URLRequest) -> (Data, HTTPURLResponse)
    ) {
        lock.withLock {
            handlers[Key(sessionID: sessionID, path: path)] = handler
        }
    }

    static func capturedRequests(sessionID: String) -> [URLRequest] {
        lock.withLock {
            captured.compactMap { $0.0 == sessionID ? $0.1 : nil }
        }
    }

    static func cleanup(sessionID: String) {
        lock.withLock {
            handlers = handlers.filter { $0.key.sessionID != sessionID }
            captured = captured.filter { $0.0 != sessionID }
        }
    }

    // MARK: URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sessionID = request.value(forHTTPHeaderField: "X-Test-Session-ID") ?? ""
        let path = request.url?.path ?? ""

        let maybeHandler: ((URLRequest) -> (Data, HTTPURLResponse))? = Self.lock.withLock {
            // Find the most-specific handler for this (sessionID, path suffix).
            Self.handlers.first { $0.key.sessionID == sessionID && path.hasSuffix($0.key.path) }?.value
        }

        Self.lock.withLock {
            Self.captured.append((sessionID, request))
        }

        if let handler = maybeHandler {
            let (data, response) = handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 500,
                httpVersion: nil,
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: "no handler".data(using: .utf8)!)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

// MARK: - OfflineURLProtocol

/// URLProtocol that always injects a URLError.notConnectedToInternet.
final class SyncOfflineURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

// MARK: - Test helpers

/// In-memory KeychainManager for tests — does not touch the real Keychain.
private final class MockSyncKeychain: KeychainManager {
    private var store: [String: String] = [:]

    override func set(key: String, value: String) throws { store[key] = value }
    override func get(key: String) throws -> String? { store[key] }
    override func delete(key: String) throws { store.removeValue(forKey: key) }
}

private func makeStubSession(sessionID: String) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncMockURLProtocol.self]
    config.httpAdditionalHeaders = ["X-Test-Session-ID": sessionID]
    return URLSession(configuration: config)
}

private func makeOfflineSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncOfflineURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeKeychain(jwt: String? = "test.jwt.token") -> MockSyncKeychain {
    let kc = MockSyncKeychain()
    if let jwt = jwt {
        try? kc.set(key: KeychainManager.Keys.coreAPIJWT, value: jwt)
    }
    return kc
}

private func makeHTTPResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

// MARK: - SyncClient Tests

@Suite("SyncClient Tests")
@MainActor
struct SyncClientTests {

    // MARK: - Authorization header

    @Test("Authorization Bearer header is derived from the Keychain JWT")
    func testAuthorizationHeaderSetFromKeychain() async throws {
        let sid = UUID().uuidString
        let expectedJWT = "eyJhbGci.testPayload.sig"
        let kc = makeKeychain(jwt: expectedJWT)
        let session = makeStubSession(sessionID: sid)

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/conversations") { req in
            (
                "[]".data(using: .utf8)!,
                makeHTTPResponse(url: req.url!, status: 200)
            )
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        _ = try await client.listConversations()

        let requests = SyncMockURLProtocol.capturedRequests(sessionID: sid)
        let authHeader = requests.first?.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == "Bearer \(expectedJWT)")
    }

    // MARK: - Successful POST / DTO decoding

    @Test("sendMessage decodes MessageDTO including serverId (ID field)")
    func testSendMessageDecodesDTO() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let convID = "conv-uuid-123"
        let msgID = "msg-server-id-456"

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convID)/messages"
        ) { req in
            let json = """
            {
              "ID": "\(msgID)",
              "TenantID": "tenant-1",
              "ConversationID": "\(convID)",
              "Role": "user",
              "Content": "hello",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        let message = try await client.sendMessage(conversationID: convID, content: "hello")

        #expect(message.ID == msgID)
        #expect(message.ConversationID == convID)
        #expect(message.Role == "user")
    }

    // MARK: - 401 maps to SyncError.unauthorized

    @Test("401 response maps to SyncError.unauthorized")
    func test401MapsToUnauthorized() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let convID = "conv-999"

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convID)/messages"
        ) { req in
            ("invalid token".data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 401))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        do {
            _ = try await client.sendMessage(conversationID: convID, content: "test")
            Issue.record("Expected SyncError.unauthorized but no error was thrown")
        } catch let syncError as SyncError {
            #expect(syncError == .unauthorized)
        }
    }

    // MARK: - Offline / transport error maps to SyncError.offline

    @Test("URLError maps to SyncError.offline")
    func testURLErrorMapsToOffline() async throws {
        let kc = makeKeychain()
        let session = makeOfflineSession()

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        do {
            _ = try await client.listConversations()
            Issue.record("Expected SyncError.offline but no error was thrown")
        } catch let syncError as SyncError {
            if case .offline = syncError {
                // Correct
            } else {
                Issue.record("Expected .offline, got \(syncError)")
            }
        }
    }

    // MARK: - Malformed JSON maps to SyncError.decodeFailed

    @Test("Malformed JSON response maps to SyncError.decodeFailed")
    func testMalformedJSONMapsToDecodeFailed() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/conversations") { req in
            ("this is not json".data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        do {
            _ = try await client.listConversations()
            Issue.record("Expected SyncError.decodeFailed but no error was thrown")
        } catch let syncError as SyncError {
            if case .decodeFailed = syncError {
                // Correct
            } else {
                Issue.record("Expected .decodeFailed, got \(syncError)")
            }
        }
    }

    // MARK: - Missing JWT maps to SyncError.unauthorized

    @Test("Missing JWT in Keychain maps to SyncError.unauthorized")
    func testMissingJWTMapsToUnauthorized() async throws {
        let kc = makeKeychain(jwt: nil)   // no JWT stored
        let session = makeOfflineSession()  // session doesn't matter — JWT check fires first

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        do {
            _ = try await client.listConversations()
            Issue.record("Expected SyncError.unauthorized but no error was thrown")
        } catch let syncError as SyncError {
            #expect(syncError == .unauthorized)
        }
    }

    // MARK: - 5xx maps to SyncError.serverError

    @Test("500 response maps to SyncError.serverError(500)")
    func test500MapsToServerError() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/recommendations/bad-id") { req in
            ("internal server error".data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 500))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        do {
            _ = try await client.getRecommendation(recommendationID: "bad-id")
            Issue.record("Expected SyncError.serverError but no error was thrown")
        } catch let syncError as SyncError {
            #expect(syncError == .serverError(500))
        }
    }

    // MARK: - WebSocket event decoding

    @Test("WSEvent decoder parses a recommendation.delivered payload")
    func testWSEventDecodesRecommendationDelivered() throws {
        let json = """
        {
          "type": "recommendation.delivered",
          "data": {
            "recommendation_id": "rec-uuid-789",
            "conversation_id": "conv-uuid-321"
          }
        }
        """
        let event = try JSONDecoder().decode(WSEvent.self, from: json.data(using: .utf8)!)

        #expect(event.type == "recommendation.delivered")
        #expect(event.data.recommendation_id == "rec-uuid-789")
        #expect(event.data.conversation_id == "conv-uuid-321")
    }

    @Test("WSEvent decoder parses a queue.updated payload")
    func testWSEventDecodesQueueUpdated() throws {
        let json = """
        {"type":"queue.updated","data":{}}
        """
        let event = try JSONDecoder().decode(WSEvent.self, from: json.data(using: .utf8)!)

        #expect(event.type == "queue.updated")
        #expect(event.data.recommendation_id == nil)
    }

    // MARK: - listMessages decodes correctly

    @Test("listMessages decodes an array of MessageDTOs")
    func testListMessagesDecodesArray() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let convID = "conv-list-test"

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convID)/messages"
        ) { req in
            let json = """
            [
              {
                "ID": "m1",
                "TenantID": "t1",
                "ConversationID": "\(convID)",
                "Role": "user",
                "Content": "hello",
                "CreatedAt": "2026-06-03T10:00:00Z"
              },
              {
                "ID": "m2",
                "TenantID": "t1",
                "ConversationID": "\(convID)",
                "Role": "assistant",
                "Content": "hi there",
                "CreatedAt": "2026-06-03T10:00:01Z"
              }
            ]
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        let messages = try await client.listMessages(conversationID: convID)

        #expect(messages.count == 2)
        #expect(messages[0].ID == "m1")
        #expect(messages[1].Role == "assistant")
    }

    // MARK: - JWT is never exposed in error descriptions

    @Test("SyncError descriptions do not contain the JWT value")
    func testErrorDescriptionsDoNotExposeJWT() async throws {
        let jwt = "super.secret.jwt.value"

        // (a) Static error cases — assert that if a future edit accidentally
        //     interpolates the token into these cases, this test catches it.
        let cases: [SyncError] = [
            .unauthorized,
            .offline(jwt),
            .decodeFailed(jwt),
            .serverError(503),
            .insecureBaseURL,
        ]
        for error in cases {
            let desc = error.errorDescription ?? ""
            #expect(!desc.contains(jwt), "errorDescription for \(error) must not contain the JWT")
            let debugDesc = String(describing: error)
            // .offline and .decodeFailed carry the reason in their debug
            // representation, which is acceptable for internal use; what
            // matters is that ONLY a sanitised localised string is shown.
            // We do NOT assert on debugDesc here — only on errorDescription.
            _ = debugDesc
        }

        // (b) End-to-end: JWT in Keychain → real offline error → description
        //     must not contain the JWT.
        let kc = makeKeychain(jwt: jwt)
        let offlineSession = makeOfflineSession()
        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: offlineSession,
            keychainManager: kc
        )

        do {
            _ = try await client.listConversations()
            Issue.record("Expected SyncError.offline but no error was thrown")
        } catch let syncError as SyncError {
            let desc = syncError.errorDescription ?? ""
            #expect(!desc.contains(jwt),
                    "errorDescription of thrown error must not contain the JWT")
            let debugDesc = String(describing: syncError)
            #expect(!debugDesc.contains(jwt),
                    "String(describing:) of thrown error must not contain the JWT")
        }
    }

    // MARK: - POST body encoding

    @Test("sendMessage encodes the content field as JSON in the request body")
    func testSendMessageRequestBodyContainsContent() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let convID = "conv-body-check"
        let messageText = "body check text"

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convID)/messages"
        ) { req in
            let json = """
            {
              "ID": "srv-body",
              "TenantID": "t1",
              "ConversationID": "\(convID)",
              "Role": "user",
              "Content": "\(messageText)",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        _ = try await client.sendMessage(conversationID: convID, content: messageText)

        // Assert the request body was encoded as {"content": "<messageText>"}.
        //
        // URLSession converts httpBody → httpBodyStream before handing the
        // request to the URLProtocol; reading httpBody directly always returns
        // nil at this point, so we drain the stream.
        let requests = SyncMockURLProtocol.capturedRequests(sessionID: sid)
        let postReq = requests.first(where: { $0.httpMethod == "POST" })
        #expect(postReq != nil, "A POST request should have been captured")

        // Drain the httpBodyStream into Data.
        var bodyData: Data? = nil
        if let stream = postReq?.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 1024
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(contentsOf: buf[0..<read])
            }
            bodyData = data.isEmpty ? nil : data
        }

        #expect(bodyData != nil, "POST request must have a body (read from httpBodyStream)")
        if let bodyData {
            let decoded = try JSONDecoder().decode([String: String].self, from: bodyData)
            #expect(decoded["content"] == messageText,
                    "POST body must contain {\"content\": \"<text>\"}")
        }
    }

    // MARK: - TLS enforcement in initialiser

    @Test("Non-localhost http:// base URL throws SyncError.insecureBaseURL")
    func testNonLocalhostHTTPThrows() throws {
        #expect(throws: SyncError.insecureBaseURL) {
            try SyncClient(
                baseURL: URL(string: "http://api.example.com")!,
                keychainManager: makeKeychain()
            )
        }
    }

    @Test("https:// remote base URL initialises without throwing")
    func testHTTPSRemoteURLSucceeds() throws {
        // Should not throw — https is safe for remote hosts.
        _ = try SyncClient(
            baseURL: URL(string: "https://api.example.com")!,
            session: makeOfflineSession(),
            keychainManager: makeKeychain()
        )
    }

    @Test("localhost http:// base URL initialises without throwing")
    func testLocalhostHTTPSucceeds() throws {
        // localhost plaintext exemption must be preserved.
        _ = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: makeOfflineSession(),
            keychainManager: makeKeychain()
        )
        _ = try SyncClient(
            baseURL: URL(string: "http://127.0.0.1:8080")!,
            session: makeOfflineSession(),
            keychainManager: makeKeychain()
        )
    }

    // MARK: - Idempotency key in POST body

    /// sendMessage with an idempotencyKey must include `idempotency_key` in the
    /// JSON body equal to the supplied key string.
    @Test("sendMessage includes idempotency_key in POST body when provided")
    func testSendMessageIncludesIdempotencyKey() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let convID = "conv-ikey-check"
        let localMsgUUID = UUID().uuidString

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convID)/messages"
        ) { req in
            let json = """
            {
              "ID": "srv-ikey",
              "TenantID": "t1",
              "ConversationID": "\(convID)",
              "Role": "user",
              "Content": "text",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        _ = try await client.sendMessage(
            conversationID: convID,
            content: "text",
            idempotencyKey: localMsgUUID
        )

        // Drain the captured request body and verify idempotency_key is present.
        let requests = SyncMockURLProtocol.capturedRequests(sessionID: sid)
        let postReq = requests.first(where: { $0.httpMethod == "POST" })
        #expect(postReq != nil, "POST request should have been captured")

        var bodyData: Data? = nil
        if let stream = postReq?.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 1024
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(contentsOf: buf[0..<read])
            }
            bodyData = data.isEmpty ? nil : data
        }

        #expect(bodyData != nil, "POST body must be present")
        if let bodyData {
            let decoded = try JSONDecoder().decode([String: String].self, from: bodyData)
            #expect(decoded["content"] == "text",
                    "POST body must contain content field")
            #expect(decoded["idempotency_key"] == localMsgUUID,
                    "POST body must contain idempotency_key equal to the local message UUID")
        }
    }

    /// sendMessage without an idempotencyKey must NOT include `idempotency_key`
    /// in the JSON body (backward-compatible with servers that have not yet
    /// applied migration 0002).
    @Test("sendMessage omits idempotency_key from POST body when not provided")
    func testSendMessageOmitsIdempotencyKeyWhenAbsent() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let convID = "conv-no-ikey"

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convID)/messages"
        ) { req in
            let json = """
            {
              "ID": "srv-no-ikey",
              "TenantID": "t1",
              "ConversationID": "\(convID)",
              "Role": "user",
              "Content": "no key",
              "CreatedAt": "2026-06-03T10:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        // Call without idempotencyKey (uses default nil).
        _ = try await client.sendMessage(conversationID: convID, content: "no key")

        let requests = SyncMockURLProtocol.capturedRequests(sessionID: sid)
        let postReq = requests.first(where: { $0.httpMethod == "POST" })
        #expect(postReq != nil)

        var bodyData: Data? = nil
        if let stream = postReq?.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            let bufSize = 1024
            var buf = [UInt8](repeating: 0, count: bufSize)
            while stream.hasBytesAvailable {
                let read = stream.read(&buf, maxLength: bufSize)
                if read <= 0 { break }
                data.append(contentsOf: buf[0..<read])
            }
            bodyData = data.isEmpty ? nil : data
        }

        #expect(bodyData != nil)
        if let bodyData {
            let decoded = try JSONDecoder().decode([String: String].self, from: bodyData)
            #expect(decoded["idempotency_key"] == nil,
                    "idempotency_key must be absent from POST body when not provided")
        }
    }

    /// A dedupe-hit response (HTTP 200 with existing message body) is treated as
    /// success — `perform` returns the MessageDTO normally.
    @Test("sendMessage treats HTTP 200 dedupe-hit response as success and returns MessageDTO")
    func testSendMessageDedupeResponseTreatedAsSuccess() async throws {
        let sid = UUID().uuidString
        let kc = makeKeychain()
        let session = makeStubSession(sessionID: sid)
        let convID = "conv-dedupe-hit"
        let existingServerID = "existing-srv-id-\(UUID().uuidString)"

        SyncMockURLProtocol.register(
            sessionID: sid,
            path: "/api/conversations/\(convID)/messages"
        ) { req in
            // Simulate a dedupe-hit: server returns 200 with the original message.
            let json = """
            {
              "ID": "\(existingServerID)",
              "TenantID": "t1",
              "ConversationID": "\(convID)",
              "Role": "user",
              "Content": "original",
              "CreatedAt": "2026-06-03T09:00:00Z"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try SyncClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session,
            keychainManager: kc
        )

        let dto = try await client.sendMessage(
            conversationID: convID,
            content: "original",
            idempotencyKey: UUID().uuidString
        )

        #expect(dto.ID == existingServerID,
                "Dedupe-hit (200) response must return the existing server message ID")
    }

    // MARK: - DTO decoding tolerates the real server shape (HouseCall-zd53)

    // The Go backend marshals store.TenantID (a [16]byte UUID) as a JSON byte
    // ARRAY, e.g. "TenantID":[0,0,...,1]. The client never uses TenantID (it
    // comes from the JWT), so the DTOs must decode successfully regardless of
    // its shape. Before the fix these decodes threw "not in the correct format",
    // silently breaking conversation create, message sync, and note delivery.

    @Test("ConversationDTO decodes the real server payload (TenantID as byte array)")
    func testConversationDTODecodesServerShape() throws {
        let json = """
        {"ID":"cc50e1b5-bf74-45be-a500-69e881c8f94e","TenantID":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],"PatientID":"00000000-0000-0000-0000-000000000020","Title":"Consultation","CreatedAt":"2026-07-01T10:00:00Z","UpdatedAt":"2026-07-01T10:00:00Z"}
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(ConversationDTO.self, from: json)
        #expect(dto.ID == "cc50e1b5-bf74-45be-a500-69e881c8f94e")
        #expect(dto.Title == "Consultation")
    }

    @Test("MessageDTO decodes the real server payload (TenantID as byte array)")
    func testMessageDTODecodesServerShape() throws {
        let json = """
        {"ID":"782982f1-0757-413e-9c0e-080452c320d4","TenantID":[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,1],"ConversationID":"cc50e1b5-bf74-45be-a500-69e881c8f94e","Role":"assistant","Content":"What brings you in today?","CreatedAt":"2026-07-01T10:00:01Z"}
        """.data(using: .utf8)!
        let dto = try JSONDecoder().decode(MessageDTO.self, from: json)
        #expect(dto.Role == "assistant")
        #expect(dto.Content == "What brings you in today?")
    }
}
