//
//  LLMProviderConfigManagerTests.swift
//  HouseCallTests
//
//  Created by Claude Code on 2025-11-23.
//  Tests for LLM provider configuration management
//

import Testing
import Foundation
@testable import HouseCall

struct LLMProviderConfigManagerTests {
    // MARK: - Provider Selection Tests

    @Test("Default provider is OpenAI")
    func testDefaultProvider() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.config.defaults")!
        userDefaults.removePersistentDomain(forName: "test.llm.config.defaults")

        let keychainManager = KeychainManager()
        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        #expect(manager.getActiveProvider() == .openai)
    }

    @Test("Set and get active provider")
    func testSetActiveProvider() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.config.setprovider")!
        userDefaults.removePersistentDomain(forName: "test.llm.config.setprovider")

        let keychainManager = KeychainManager()
        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        manager.setActiveProvider(.claude)

        #expect(manager.getActiveProvider() == .claude)
    }

    @Test("Active provider persists across instances")
    func testProviderPersistence() throws {
        let suiteName = "test.llm.config.persistence"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)

        let keychainManager = KeychainManager()

        // First instance sets provider
        let manager1 = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )
        manager1.setActiveProvider(.custom)

        // Second instance should load the same provider
        let manager2 = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        #expect(manager2.getActiveProvider() == .custom)
    }

    // MARK: - API Key Management Tests

    @Test("Save and retrieve API key for OpenAI")
    func testSaveOpenAIAPIKey() throws {
        let keychainManager = KeychainManager()
        let userDefaults = UserDefaults(suiteName: "test.llm.apikey.openai")!
        userDefaults.removePersistentDomain(forName: "test.llm.apikey.openai")

        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        let testKey = "sk-test-openai-key-12345"
        try manager.saveAPIKey(testKey, for: .openai)

        let retrievedKey = manager.getAPIKey(for: .openai)
        #expect(retrievedKey == testKey)

        // Cleanup
        try? manager.deleteAPIKey(for: .openai)
    }

    @Test("Save and retrieve API key for Claude")
    func testSaveClaudeAPIKey() throws {
        let keychainManager = KeychainManager()
        let userDefaults = UserDefaults(suiteName: "test.llm.apikey.claude")!
        userDefaults.removePersistentDomain(forName: "test.llm.apikey.claude")

        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        let testKey = "sk-ant-test-claude-key-67890"
        try manager.saveAPIKey(testKey, for: .claude)

        let retrievedKey = manager.getAPIKey(for: .claude)
        #expect(retrievedKey == testKey)

        // Cleanup
        try? manager.deleteAPIKey(for: .claude)
    }

    @Test("Delete API key")
    func testDeleteAPIKey() throws {
        let keychainManager = KeychainManager()
        let userDefaults = UserDefaults(suiteName: "test.llm.apikey.delete")!
        userDefaults.removePersistentDomain(forName: "test.llm.apikey.delete")

        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        // Save key
        try manager.saveAPIKey("test-key", for: .openai)
        #expect(manager.hasAPIKey(for: .openai) == true)

        // Delete key
        try manager.deleteAPIKey(for: .openai)
        #expect(manager.hasAPIKey(for: .openai) == false)
    }

    @Test("hasAPIKey returns false for non-existent key")
    func testHasAPIKeyNonExistent() throws {
        let keychainManager = KeychainManager()
        let userDefaults = UserDefaults(suiteName: "test.llm.apikey.nonexist")!
        userDefaults.removePersistentDomain(forName: "test.llm.apikey.nonexist")

        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        #expect(manager.hasAPIKey(for: .custom) == false)
    }

    // MARK: - OpenAI Configuration Tests

    @Test("Save and load OpenAI configuration")
    func testOpenAIConfiguration() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.config.openai")!
        userDefaults.removePersistentDomain(forName: "test.llm.config.openai")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let config = OpenAIConfig(
            model: "gpt-4-turbo",
            temperature: 0.8,
            maxTokens: 2000
        )

        manager.saveOpenAIConfig(config)
        let loadedConfig = manager.loadOpenAIConfig()

        #expect(loadedConfig.model == "gpt-4-turbo")
        #expect(loadedConfig.temperature == 0.8)
        #expect(loadedConfig.maxTokens == 2000)
    }

    @Test("Load default OpenAI config when none saved")
    func testDefaultOpenAIConfig() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.config.openai.default")!
        userDefaults.removePersistentDomain(forName: "test.llm.config.openai.default")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let config = manager.loadOpenAIConfig()

        #expect(config.model == "gpt-4")
        #expect(config.temperature == 0.7)
        #expect(config.maxTokens == 1000)
    }

    // MARK: - Claude Configuration Tests

    @Test("Save and load Claude configuration")
    func testClaudeConfiguration() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.config.claude")!
        userDefaults.removePersistentDomain(forName: "test.llm.config.claude")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let config = ClaudeConfig(
            model: "claude-3-opus-20240229",
            temperature: 0.9,
            maxTokens: 1500
        )

        manager.saveClaudeConfig(config)
        let loadedConfig = manager.loadClaudeConfig()

        #expect(loadedConfig.model == "claude-3-opus-20240229")
        #expect(loadedConfig.temperature == 0.9)
        #expect(loadedConfig.maxTokens == 1500)
    }

    // MARK: - Custom Provider Configuration Tests

    @Test("Save and load custom provider configuration")
    func testCustomProviderConfiguration() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.config.custom")!
        userDefaults.removePersistentDomain(forName: "test.llm.config.custom")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434",
            endpoint: "v1/chat/completions",
            model: "llama3",
            temperature: 0.6,
            maxTokens: 800,
            requiresAuth: false
        )

        manager.saveCustomProviderConfig(config)
        let loadedConfig = manager.loadCustomProviderConfig()

        #expect(loadedConfig?.baseURL == "http://localhost:11434")
        #expect(loadedConfig?.model == "llama3")
        #expect(loadedConfig?.temperature == 0.6)
        #expect(loadedConfig?.requiresAuth == false)
    }

    @Test("Load nil for non-existent custom config")
    func testNonExistentCustomConfig() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.config.custom.nonexist")!
        userDefaults.removePersistentDomain(forName: "test.llm.config.custom.nonexist")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let config = manager.loadCustomProviderConfig()

        #expect(config == nil)
    }

    // MARK: - Provider Instance Creation Tests

    @Test("Create OpenAI provider instance")
    func testCreateOpenAIProvider() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.create.openai")!
        userDefaults.removePersistentDomain(forName: "test.llm.create.openai")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let provider = manager.createProvider(type: .openai)

        #expect(provider != nil)
        #expect(provider?.providerType == .openai)
    }

    @Test("Create Claude provider instance")
    func testCreateClaudeProvider() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.create.claude")!
        userDefaults.removePersistentDomain(forName: "test.llm.create.claude")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let provider = manager.createProvider(type: .claude)

        #expect(provider != nil)
        #expect(provider?.providerType == .claude)
    }

    @Test("Return nil for custom provider without config")
    func testCreateCustomProviderWithoutConfig() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.create.custom.noconfig")!
        userDefaults.removePersistentDomain(forName: "test.llm.create.custom.noconfig")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let provider = manager.createProvider(type: .custom)

        #expect(provider == nil)
    }

    // MARK: - Provider Configuration Status Tests

    @Test("OpenAI is not configured without API key")
    func testOpenAINotConfigured() throws {
        let keychainManager = KeychainManager()
        let userDefaults = UserDefaults(suiteName: "test.llm.status.openai.notconfig")!
        userDefaults.removePersistentDomain(forName: "test.llm.status.openai.notconfig")

        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        // Ensure no API key exists
        try? manager.deleteAPIKey(for: .openai)

        #expect(manager.isProviderConfigured(.openai) == false)
    }

    @Test("OpenAI is configured with API key")
    func testOpenAIConfigured() throws {
        let keychainManager = KeychainManager()
        let userDefaults = UserDefaults(suiteName: "test.llm.status.openai.config")!
        userDefaults.removePersistentDomain(forName: "test.llm.status.openai.config")

        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        try manager.saveAPIKey("test-key", for: .openai)

        #expect(manager.isProviderConfigured(.openai) == true)

        // Cleanup
        try? manager.deleteAPIKey(for: .openai)
    }

    @Test("Custom provider configured with valid URL and no auth")
    func testCustomProviderConfiguredNoAuth() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.status.custom.noauth")!
        userDefaults.removePersistentDomain(forName: "test.llm.status.custom.noauth")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434",
            model: "llama3",
            requiresAuth: false
        )
        manager.saveCustomProviderConfig(config)

        #expect(manager.isProviderConfigured(.custom) == true)
    }

    @Test("Custom provider not configured with invalid URL")
    func testCustomProviderInvalidURL() throws {
        let userDefaults = UserDefaults(suiteName: "test.llm.status.custom.invalidurl")!
        userDefaults.removePersistentDomain(forName: "test.llm.status.custom.invalidurl")

        let manager = LLMProviderConfigManager(
            keychainManager: KeychainManager(),
            userDefaults: userDefaults
        )

        let config = CustomProviderConfig(
            baseURL: "not a valid url",
            model: "llama3"
        )
        manager.saveCustomProviderConfig(config)

        #expect(manager.isProviderConfigured(.custom) == false)
    }

    @Test("Custom provider requires API key when auth is required")
    func testCustomProviderRequiresAuth() throws {
        let keychainManager = KeychainManager()
        let userDefaults = UserDefaults(suiteName: "test.llm.status.custom.reqauth")!
        userDefaults.removePersistentDomain(forName: "test.llm.status.custom.reqauth")

        let manager = LLMProviderConfigManager(
            keychainManager: keychainManager,
            userDefaults: userDefaults
        )

        let config = CustomProviderConfig(
            baseURL: "https://api.example.com",
            model: "custom-model",
            requiresAuth: true
        )
        manager.saveCustomProviderConfig(config)

        // Without API key, should not be configured
        try? manager.deleteAPIKey(for: .custom)
        #expect(manager.isProviderConfigured(.custom) == false)

        // With API key, should be configured
        try manager.saveAPIKey("test-key", for: .custom)
        #expect(manager.isProviderConfigured(.custom) == true)

        // Cleanup
        try? manager.deleteAPIKey(for: .custom)
    }
}
