//
//  CoreAPIAuthClient.swift
//  HouseCall
//
//  Pre-authentication REST client for the HouseCall Core API.
//
//  Responsibilities:
//  - POST credentials to /api/auth/login → CoreAPIAuthResult
//  - POST credentials to /api/auth/register → CoreAPIAuthResult
//
//  This client requires NO JWT — these endpoints are the only way to
//  *obtain* a JWT.  Wiring into AuthenticationService is deferred to
//  task 3.x; this file is a self-contained testable seam.
//
//  HIPAA guardrails:
//  - Plaintext passwords are sent only in the HTTPS/TLS request body;
//    they are NEVER logged, printed, or placed in error descriptions.
//  - TLS is required for any non-localhost base URL (same rule as SyncClient).
//

import Foundation

// MARK: - Public result type

/// The normalised result returned by both `login` and `register`.
struct CoreAPIAuthResult {
    /// JWT to store via `AuthenticationService.storeCoreAPIJWT(_:)`.
    let token: String
    /// Server-canonical patient UUID.  Used as the HKDF salt for
    /// device-local encryption key derivation so encryption identity
    /// stays stable and purely device-local.
    let patientId: String
}

// MARK: - Private response DTOs
//
// These mirror the Go JSON field names exactly (snake_case, as declared
// in auth.go with explicit json struct tags).
//
//   loginResponse    → { token, actor_type, actor_id }
//   registerResponse → { token, actor_type, actor_id, patient_id }

private struct LoginResponseDTO: Decodable {
    let token: String
    /// For patient actors actor_id equals the patient UUID.
    let actor_id: String
}

private struct RegisterResponseDTO: Decodable {
    let token: String
    /// Canonical patient UUID; equal to actor_id for patient registrations.
    let patient_id: String
}

// MARK: - CoreAPIAuthClientProtocol

/// Testable seam for the Core API auth client.
///
/// Inject a conforming stub in unit tests to avoid live network calls.
/// `CoreAPIAuthClient` is the production conformer; tests use
/// `StubCoreAPIAuthClient` (defined in HouseCallTests).
protocol CoreAPIAuthClientProtocol {
    /// Authenticate an existing patient account.
    func login(tenantId: String, email: String, password: String) async throws -> CoreAPIAuthResult

    /// Register a new patient account. `state` is an optional USPS 2-letter code
    /// determining which licensed physician may review the patient.
    func register(tenantId: String, email: String, password: String, state: String?) async throws -> CoreAPIAuthResult
}

// MARK: - CoreAPIAuthClient

/// Dedicated pre-auth REST client.
///
/// Inject a custom `URLSession` in tests to avoid live network calls
/// (see `CoreAPIAuthClientTests`).
final class CoreAPIAuthClient: CoreAPIAuthClientProtocol {

    // MARK: - Dependencies

    private let baseURL: URL
    private let session: URLSession

    // MARK: - Initialisation

    /// - Parameters:
    ///   - baseURL: Core API host.  Default: `http://localhost:8080`.
    ///     Any non-localhost URL **must** use `https://`.
    ///   - session: URLSession for requests.  Defaults to `URLSession.shared`.
    ///     Provide a stub session in tests.
    /// - Throws: `SyncError.insecureBaseURL` if `baseURL` is non-localhost
    ///   and does not use the `https` scheme.
    init(
        baseURL: URL = URL(string: "http://localhost:8080")!,
        session: URLSession = .shared
    ) throws {
        let host = baseURL.host ?? ""
        let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        if !isLocalhost && baseURL.scheme != "https" {
            throw SyncError.insecureBaseURL
        }
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Public API

    /// Authenticate an existing patient (or physician) account.
    ///
    /// Maps to `POST /api/auth/login`.
    ///
    /// - Parameters:
    ///   - tenantId: Tenant UUID string (from `CoreAPITenantID` config).
    ///   - email: Account email address.
    ///   - password: Plaintext password (sent over TLS; never logged).
    /// - Returns: `CoreAPIAuthResult` containing the JWT and the patient UUID.
    /// - Throws:
    ///   - `SyncError.unauthorized` on HTTP 401.
    ///   - `SyncError.serverError(code)` on other non-2xx responses.
    ///   - `SyncError.offline(reason)` when the server is unreachable or the
    ///     transport fails; callers MUST distinguish this from `.unauthorized`
    ///     to enable the phase-4 offline fallback.
    func login(
        tenantId: String,
        email: String,
        password: String
    ) async throws -> CoreAPIAuthResult {
        let body = try encodeBody(tenantId: tenantId, email: email, password: password)
        let request = try buildRequest(path: "/api/auth/login", body: body)
        let dto: LoginResponseDTO = try await perform(request)
        return CoreAPIAuthResult(token: dto.token, patientId: dto.actor_id)
    }

    /// Register a new patient account.
    ///
    /// Maps to `POST /api/auth/register`.
    ///
    /// - Parameters:
    ///   - tenantId: Tenant UUID string.
    ///   - email: Desired email address.
    ///   - password: Plaintext password (sent over TLS; never logged).
    /// - Returns: `CoreAPIAuthResult` with the JWT and the newly-created
    ///   patient UUID.  The caller should key local storage on `patientId`
    ///   immediately so the encryption identity matches the server-canonical id.
    /// - Throws:
    ///   - `SyncError.conflict` if the email is already registered for this
    ///     tenant (HTTP 409 "email already registered").
    ///   - `SyncError.unauthorized` on HTTP 401.
    ///   - `SyncError.serverError(code)` on other non-2xx responses.
    ///   - `SyncError.offline(reason)` when the server is unreachable.
    func register(
        tenantId: String,
        email: String,
        password: String,
        state: String?
    ) async throws -> CoreAPIAuthResult {
        let body = try encodeBody(tenantId: tenantId, email: email, password: password, state: state)
        let request = try buildRequest(path: "/api/auth/register", body: body)
        let dto: RegisterResponseDTO = try await perform(request)
        return CoreAPIAuthResult(token: dto.token, patientId: dto.patient_id)
    }

    // MARK: - Private helpers

    /// Encode `{tenant_id, email, password}` as JSON.
    ///
    /// The password value is encoded into the request body.
    /// It must never appear in logs, error strings, or debug output.
    private func encodeBody(tenantId: String, email: String, password: String, state: String? = nil) throws -> Data {
        var dict: [String: String] = [
            "tenant_id": tenantId,
            "email": email,
            "password": password
        ]
        if let state, !state.isEmpty {
            dict["state"] = state
        }
        return try JSONEncoder().encode(dict)
    }

    private func buildRequest(path: String, body: Data) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw SyncError.offline("invalid path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// Execute a request and decode the response body into `T`.
    ///
    /// Error mapping (mirrors SyncClient.perform for consistent error taxonomy):
    /// - Transport / URLError          → `SyncError.offline(...)`
    /// - HTTP 401                      → `SyncError.unauthorized`
    /// - HTTP 409                      → `SyncError.conflict`
    /// - Other non-2xx                 → `SyncError.serverError(code)`
    /// - Decode failure                → `SyncError.decodeFailed(...)`
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

        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            throw SyncError.unauthorized
        case 409:
            throw SyncError.conflict
        default:
            throw SyncError.serverError(http.statusCode)
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let decodeError {
            throw SyncError.decodeFailed(decodeError.localizedDescription)
        }
    }
}
