//
//  LLMProviderConfigManager.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  Manages LLM provider configuration and API keys
//

import Foundation
import Combine

/// Manages configuration for all LLM providers
class LLMProviderConfigManager: ObservableObject {
    // MARK: - Singleton

    static let shared = LLMProviderConfigManager()

    // MARK: - Properties

    private let keychainManager: KeychainManager
    private let userDefaults: UserDefaults

    /// Key prefix for UserDefaults storage
    private let configKeyPrefix = "llm_provider_config"

    /// Currently active provider type
    @Published private(set) var activeProvider: LLMProviderType {
        didSet {
            saveActiveProvider()
        }
    }

    // MARK: - Initialization

    init(
        keychainManager: KeychainManager = .shared,
        userDefaults: UserDefaults = .standard
    ) {
        self.keychainManager = keychainManager
        self.userDefaults = userDefaults

        // Load active provider from UserDefaults
        if let savedProviderString = userDefaults.string(forKey: "\(configKeyPrefix)_active"),
           let savedProvider = LLMProviderType(rawValue: savedProviderString) {
            self.activeProvider = savedProvider
        } else {
            // Default to OpenAI
            self.activeProvider = .openai
        }
    }

    // MARK: - Provider Selection

    /// Set the active provider
    func setActiveProvider(_ provider: LLMProviderType) {
        activeProvider = provider
    }

    /// Get the current active provider
    func getActiveProvider() -> LLMProviderType {
        return activeProvider
    }

    // MARK: - API Key Management

    /// Save API key for a provider
    func saveAPIKey(_ key: String, for provider: LLMProviderType) throws {
        let keychainKey = getAPIKeyKey(for: provider)
        try keychainManager.save(key, forKey: keychainKey)
    }

    /// Retrieve API key for a provider
    func getAPIKey(for provider: LLMProviderType) -> String? {
        let keychainKey = getAPIKeyKey(for: provider)
        return try? keychainManager.get(key: keychainKey)
    }

    /// Delete API key for a provider
    func deleteAPIKey(for provider: LLMProviderType) throws {
        let keychainKey = getAPIKeyKey(for: provider)
        try keychainManager.delete(key: keychainKey)
    }

    /// Check if provider has an API key configured
    func hasAPIKey(for provider: LLMProviderType) -> Bool {
        return getAPIKey(for: provider) != nil
    }

    // MARK: - OpenAI Configuration

    /// Save OpenAI configuration
    func saveOpenAIConfig(_ config: OpenAIConfig) {
        let key = "\(configKeyPrefix)_openai"
        if let encoded = try? JSONEncoder().encode(config) {
            userDefaults.set(encoded, forKey: key)
        }
    }

    /// Load OpenAI configuration
    func loadOpenAIConfig() -> OpenAIConfig {
        let key = "\(configKeyPrefix)_openai"
        if let data = userDefaults.data(forKey: key),
           let config = try? JSONDecoder().decode(OpenAIConfig.self, from: data) {
            return config
        }
        // Return default config
        return OpenAIConfig()
    }

    // MARK: - Claude Configuration

    /// Save Claude configuration
    func saveClaudeConfig(_ config: ClaudeConfig) {
        let key = "\(configKeyPrefix)_claude"
        if let encoded = try? JSONEncoder().encode(config) {
            userDefaults.set(encoded, forKey: key)
        }
    }

    /// Load Claude configuration
    func loadClaudeConfig() -> ClaudeConfig {
        let key = "\(configKeyPrefix)_claude"
        if let data = userDefaults.data(forKey: key),
           let config = try? JSONDecoder().decode(ClaudeConfig.self, from: data) {
            return config
        }
        // Return default config
        return ClaudeConfig()
    }

    // MARK: - Custom Provider Configuration

    /// Save custom provider configuration
    func saveCustomProviderConfig(_ config: CustomProviderConfig) {
        let key = "\(configKeyPrefix)_custom"
        if let encoded = try? JSONEncoder().encode(config) {
            userDefaults.set(encoded, forKey: key)
        }
    }

    /// Load custom provider configuration
    func loadCustomProviderConfig() -> CustomProviderConfig? {
        let key = "\(configKeyPrefix)_custom"
        if let data = userDefaults.data(forKey: key),
           let config = try? JSONDecoder().decode(CustomProviderConfig.self, from: data) {
            return config
        }
        return nil
    }

    // MARK: - Provider Instance Creation

    /// Create an instance of the active provider
    func createActiveProvider() -> LLMProvider? {
        return createProvider(type: activeProvider)
    }

    /// Create a provider instance by type
    func createProvider(type: LLMProviderType) -> LLMProvider? {
        switch type {
        case .openai:
            let config = loadOpenAIConfig()
            return OpenAIProvider(config: config)

        case .claude:
            let config = loadClaudeConfig()
            return ClaudeProvider(config: config)

        case .custom:
            guard let config = loadCustomProviderConfig() else {
                return nil
            }
            return CustomProvider(config: config)
        }
    }

    /// Check if a provider is configured and ready to use
    func isProviderConfigured(_ type: LLMProviderType) -> Bool {
        switch type {
        case .openai, .claude:
            return hasAPIKey(for: type)

        case .custom:
            guard let customConfig = loadCustomProviderConfig() else {
                return false
            }
            // Custom provider needs a valid URL at minimum
            guard URL(string: customConfig.baseURL) != nil else {
                return false
            }
            // If auth is required, check for API key
            if customConfig.requiresAuth {
                return hasAPIKey(for: type)
            }
            return true
        }
    }

    // MARK: - Private Helpers

    private func getAPIKeyKey(for provider: LLMProviderType) -> String {
        switch provider {
        case .openai:
            return "openai_api_key"
        case .claude:
            return "claude_api_key"
        case .custom:
            return "custom_provider_api_key"
        }
    }

    private func saveActiveProvider() {
        userDefaults.set(activeProvider.rawValue, forKey: "\(configKeyPrefix)_active")
    }
}

// MARK: - Codable Extensions

extension OpenAIConfig: Codable {}
extension ClaudeConfig: Codable {}

extension CustomProviderConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case baseURL
        case endpoint
        case model
        case temperature
        case maxTokens
        case requiresAuth
    }
}
