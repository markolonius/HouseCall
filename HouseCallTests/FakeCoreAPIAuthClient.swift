//
//  FakeCoreAPIAuthClient.swift
//  HouseCallTests
//
//  Shared always-succeeding Core API auth client for tests that need a
//  configured AuthenticationService but do not care about the network layer.
//

import Foundation
@testable import HouseCall

final class FakeCoreAPIAuthClient: CoreAPIAuthClientProtocol, @unchecked Sendable {
    static let tenantId = "test-tenant"

    /// When true, `login` throws `SyncError.offline`, exercising the cloud
    /// path's offline fallback (local credential check + local audit events).
    var loginOffline = false

    private let lock = NSLock()
    private var patientIds: [String: String] = [:]

    /// Pre-seed the patient id the server "knows" for an email so a test that
    /// created a local user directly can log in as that same identity.
    func seed(email: String, patientId: UUID) {
        lock.lock(); defer { lock.unlock() }
        patientIds[email.lowercased()] = patientId.uuidString
    }

    func login(tenantId: String, email: String, password: String) async throws -> CoreAPIAuthResult {
        if loginOffline { throw SyncError.offline("fake offline") }
        return CoreAPIAuthResult(token: "fake.jwt.token", patientId: patientId(for: email))
    }

    func register(tenantId: String, email: String, password: String, state: String?) async throws -> CoreAPIAuthResult {
        CoreAPIAuthResult(token: "fake.jwt.token", patientId: patientId(for: email))
    }

    private func patientId(for email: String) -> String {
        lock.lock(); defer { lock.unlock() }
        let key = email.lowercased()
        if let existing = patientIds[key] { return existing }
        let id = UUID().uuidString
        patientIds[key] = id
        return id
    }
}
