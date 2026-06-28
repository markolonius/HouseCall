//
//  CoreAPIConfig.swift
//  HouseCall
//
//  Build-time Core API configuration helpers.
//
//  Both HouseCallApp and AuthenticationService read these values at startup.
//  Centralising the readers here provides a single source of truth and avoids
//  duplicating the placeholder-guard logic.
//
//  HIPAA: these helpers return identifiers (URLs, tenant IDs) only — never
//  credentials, tokens, or any PHI.
//

import Foundation

/// Namespace for Core API build-time configuration readers.
///
/// Values are populated at build time via xcconfig/Info.plist.
/// Every reader returns `nil` when the value is absent, empty, or still
/// contains an unsubstituted xcconfig placeholder (e.g. `$(CORE_API_BASE_URL)`).
/// Callers treat `nil` as "cloud auth/sync disabled".
enum CoreAPIConfig {

    // MARK: - Base URL

    /// Returns the Core API base URL string from `Info.plist` when it has
    /// been substituted by xcconfig at build time.
    ///
    /// Returns `nil` when `CoreAPIBaseURL` is absent, empty, or contains an
    /// unsubstituted placeholder such as `$(CORE_API_BASE_URL)`.
    static func baseURLString() -> String? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "CoreAPIBaseURL") as? String,
            !value.isEmpty,
            !value.hasPrefix("$(")
        else { return nil }
        return value
    }

    // MARK: - Tenant ID

    /// Returns the Core API tenant UUID string from `Info.plist` when it has
    /// been substituted by xcconfig at build time.
    ///
    /// Returns `nil` when `CoreAPITenantID` is absent, empty, or contains an
    /// unsubstituted placeholder such as `$(CORE_API_TENANT_ID)`.
    /// Cloud auth is disabled whenever this returns `nil`.
    static func tenantID() -> String? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "CoreAPITenantID") as? String,
            !value.isEmpty,
            !value.hasPrefix("$(")
        else { return nil }
        return value
    }
}
