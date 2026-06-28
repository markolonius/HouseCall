//
//  CoreAPIAuthClientTests.swift
//  HouseCallTests
//
//  Unit tests for CoreAPIAuthClient (Task 2.1).
//
//  All network calls are intercepted by SyncMockURLProtocol (defined in
//  SyncClientTests.swift, internal to the HouseCallTests module).
//  Tests follow the same Swift Testing (@Suite / @Test / #expect) style
//  used across HouseCallTests.
//

import Testing
import Foundation
@testable import HouseCall

// MARK: - Body capture helpers
//
// URLSession passes the request body to URLProtocol via `httpBodyStream`
// (not `httpBody`) in many configurations.  These helpers let tests read
// the body bytes regardless of which property is populated.

/// Thread-safe box for a captured request body.
/// `@unchecked Sendable` is intentional: the test controls the write-then-read
/// ordering across the async boundary, so no additional locking is required.
private final class BodyCapture: @unchecked Sendable {
    var data: Data?
}

/// Drain an `InputStream` into `Data`.  The stream is opened and closed here.
private func readStream(_ stream: InputStream) -> Data {
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    stream.open()
    while stream.hasBytesAvailable {
        let n = stream.read(buffer, maxLength: bufferSize)
        if n > 0 { data.append(buffer, count: n) }
    }
    stream.close()
    return data
}

// MARK: - Session factories
//
// Private helpers that mirror the pattern in SyncClientTests.  They must
// be redeclared here because the originals are file-private.

private func makeAuthStubSession(sessionID: String) -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncMockURLProtocol.self]
    config.httpAdditionalHeaders = ["X-Test-Session-ID": sessionID]
    return URLSession(configuration: config)
}

private func makeAuthOfflineSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [SyncOfflineURLProtocol.self]
    return URLSession(configuration: config)
}

private func makeHTTPResponse(url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
}

// MARK: - CoreAPIAuthClient Tests

@Suite("CoreAPIAuthClient Tests")
@MainActor
struct CoreAPIAuthClientTests {

    // MARK: - register: success (201)

    @Test("register decodes token and patient_id from 201 response")
    func testRegisterSuccess() async throws {
        let sid = UUID().uuidString
        let session = makeAuthStubSession(sessionID: sid)

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/auth/register") { req in
            let json = """
            {
              "token": "jwt.register.tok",
              "actor_type": "patient",
              "actor_id": "patient-uuid-abc",
              "patient_id": "patient-uuid-abc"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try CoreAPIAuthClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session
        )
        let result = try await client.register(
            tenantId: "tenant-1",
            email: "patient@example.com",
            password: "TestPassword123!"
        )

        #expect(result.token == "jwt.register.tok")
        #expect(result.patientId == "patient-uuid-abc")
    }

    // MARK: - register: password is sent in the request body

    @Test("register sends password in the request body (not exposed via logs)")
    func testRegisterPasswordInRequestBody() async throws {
        let sid = UUID().uuidString
        let session = makeAuthStubSession(sessionID: sid)
        let expectedPassword = "SecurePass999!"

        // URLSession hands the body to URLProtocol via httpBodyStream, not
        // httpBody.  Capture the raw bytes inside the handler where the stream
        // is still open (and where httpBody may still be set on some runtimes).
        let bodyCapture = BodyCapture()

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/auth/register") { req in
            if let body = req.httpBody {
                bodyCapture.data = body
            } else if let stream = req.httpBodyStream {
                bodyCapture.data = readStream(stream)
            }
            let json = """
            {"token":"tok","actor_type":"patient","actor_id":"pid","patient_id":"pid"}
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 201))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try CoreAPIAuthClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session
        )
        _ = try await client.register(
            tenantId: "t-1",
            email: "a@b.com",
            password: expectedPassword
        )

        let bodyData = try #require(bodyCapture.data, "Request body was not captured")
        // Must be a valid JSON dictionary with the password field.
        let bodyDict = try JSONDecoder().decode([String: String].self, from: bodyData)
        #expect(bodyDict["password"] == expectedPassword)
        #expect(bodyDict["email"] == "a@b.com")
        #expect(bodyDict["tenant_id"] == "t-1")
    }

    // MARK: - login: success (200)

    @Test("login decodes token and actor_id as patientId from 200 response")
    func testLoginSuccess() async throws {
        let sid = UUID().uuidString
        let session = makeAuthStubSession(sessionID: sid)

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/auth/login") { req in
            let json = """
            {
              "token": "jwt.login.tok",
              "actor_type": "patient",
              "actor_id": "patient-uuid-xyz"
            }
            """
            return (json.data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 200))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try CoreAPIAuthClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session
        )
        let result = try await client.login(
            tenantId: "tenant-1",
            email: "patient@example.com",
            password: "TestPassword123!"
        )

        #expect(result.token == "jwt.login.tok")
        #expect(result.patientId == "patient-uuid-xyz")
    }

    // MARK: - 401 → SyncError.unauthorized

    @Test("401 response maps to SyncError.unauthorized")
    func test401MapsToUnauthorized() async throws {
        let sid = UUID().uuidString
        let session = makeAuthStubSession(sessionID: sid)

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/auth/login") { req in
            ("invalid credentials".data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 401))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try CoreAPIAuthClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session
        )

        do {
            _ = try await client.login(
                tenantId: "t-1",
                email: "bad@example.com",
                password: "wrongpw"
            )
            Issue.record("Expected SyncError.unauthorized but no error was thrown")
        } catch let err as SyncError {
            #expect(err == .unauthorized)
        }
    }

    // MARK: - 409 → SyncError.conflict

    @Test("409 response maps to SyncError.conflict")
    func test409MapsToConflict() async throws {
        let sid = UUID().uuidString
        let session = makeAuthStubSession(sessionID: sid)

        SyncMockURLProtocol.register(sessionID: sid, path: "/api/auth/register") { req in
            ("email already registered".data(using: .utf8)!, makeHTTPResponse(url: req.url!, status: 409))
        }
        defer { SyncMockURLProtocol.cleanup(sessionID: sid) }

        let client = try CoreAPIAuthClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session
        )

        do {
            _ = try await client.register(
                tenantId: "t-1",
                email: "existing@example.com",
                password: "SomePassword!"
            )
            Issue.record("Expected SyncError.conflict but no error was thrown")
        } catch let err as SyncError {
            #expect(err == .conflict)
        }
    }

    // MARK: - Transport failure → SyncError.offline

    @Test("URLError (unreachable) maps to SyncError.offline — distinct from .unauthorized")
    func testTransportFailureMapsToOffline() async throws {
        let session = makeAuthOfflineSession()

        let client = try CoreAPIAuthClient(
            baseURL: URL(string: "http://localhost:8080")!,
            session: session
        )

        do {
            _ = try await client.login(
                tenantId: "t-1",
                email: "patient@example.com",
                password: "SomePassword!"
            )
            Issue.record("Expected SyncError.offline but no error was thrown")
        } catch let err as SyncError {
            // Must be .offline — NOT .unauthorized.  This distinction is
            // required for the phase-4 offline fallback to local credentials.
            if case .offline = err {
                // Expected — transport layer failure correctly signalled.
            } else {
                Issue.record("Expected SyncError.offline, got \(err)")
            }
        }
    }

    // MARK: - Insecure base URL

    @Test("Non-localhost http:// base URL is rejected at init with insecureBaseURL")
    func testInsecureBaseURLRejected() throws {
        #expect(throws: SyncError.insecureBaseURL) {
            try CoreAPIAuthClient(baseURL: URL(string: "http://example.com")!)
        }
    }

    // MARK: - HTTPS base URL accepted

    @Test("https:// non-localhost base URL is accepted at init")
    func testHTTPSBaseURLAccepted() throws {
        #expect(throws: Never.self) {
            _ = try CoreAPIAuthClient(baseURL: URL(string: "https://api.example.com")!)
        }
    }
}
