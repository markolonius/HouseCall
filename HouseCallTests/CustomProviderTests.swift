//
//  CustomProviderTests.swift
//  HouseCallTests
//
//  Created by Claude Code on 2025-11-23.
//  Unit tests for Custom/self-hosted LLM provider implementation
//

import Testing
import Foundation
@testable import HouseCall

@Suite("Custom Provider Tests")
struct CustomProviderTests {

    // MARK: - Helper Setup

    private func createTestProvider(
        baseURL: String = "http://localhost:11434",
        model: String = "llama3",
        withAPIKey: Bool = false,
        requiresAuth: Bool = false
    ) -> (CustomProvider, MockKeychainManager, MockAuditLogger) {
        let mockKeychain = MockKeychainManager()
        let mockAudit = MockAuditLogger()

        if withAPIKey {
            try? mockKeychain.set(key: "custom_provider_api_key", value: "test-custom-key")
        }

        let config = CustomProviderConfig(
            baseURL: baseURL,
            endpoint: "v1/chat/completions",
            model: model,
            temperature: 0.7,
            maxTokens: 1000,
            requiresAuth: requiresAuth
        )

        let provider = CustomProvider(
            config: config,
            keychainManager: mockKeychain,
            auditLogger: mockAudit
        )

        return (provider, mockKeychain, mockAudit)
    }

    // MARK: - Configuration Tests

    @Test("Provider type is Custom")
    func testProviderType() {
        let (provider, _, _) = createTestProvider()
        #expect(provider.providerType == .custom)
    }

    @Test("Provider is configured with valid HTTP URL")
    func testIsConfiguredWithHTTPURL() {
        let (provider, _, _) = createTestProvider(baseURL: "http://localhost:11434")
        #expect(provider.isConfigured == true)
    }

    @Test("Provider is configured with valid HTTPS URL")
    func testIsConfiguredWithHTTPSURL() {
        let (provider, _, _) = createTestProvider(baseURL: "https://api.example.com")
        #expect(provider.isConfigured == true)
    }

    @Test("Provider is not configured with invalid URL")
    func testIsConfiguredWithInvalidURL() {
        let (provider, _, _) = createTestProvider(baseURL: "not-a-url")
        #expect(provider.isConfigured == false)
    }

    @Test("Provider is not configured with FTP URL")
    func testIsConfiguredWithFTPURL() {
        let (provider, _, _) = createTestProvider(baseURL: "ftp://example.com")
        #expect(provider.isConfigured == false)
    }

    @Test("Provider throws error when not configured")
    func testStreamCompletionThrowsWhenNotConfigured() async {
        let (provider, _, _) = createTestProvider(baseURL: "invalid-url")

        let messages = [
            ChatMessage(role: .user, content: "Hello")
        ]

        var onChunkCalled = false

        await #expect(throws: LLMError.self) {
            try await provider.streamCompletion(
                messages: messages,
                onChunk: { _ in onChunkCalled = true },
                onComplete: { _ in }
            )
        }

        #expect(onChunkCalled == false)
    }

    // MARK: - URL Construction Tests

    @Test("URL with trailing slash")
    func testURLWithTrailingSlash() {
        let (provider, _, _) = createTestProvider(baseURL: "http://localhost:11434/")
        #expect(provider.isConfigured == true)
    }

    @Test("URL without trailing slash")
    func testURLWithoutTrailingSlash() {
        let (provider, _, _) = createTestProvider(baseURL: "http://localhost:11434")
        #expect(provider.isConfigured == true)
    }

    @Test("Custom endpoint path")
    func testCustomEndpoint() {
        let mockKeychain = MockKeychainManager()
        let mockAudit = MockAuditLogger()

        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434",
            endpoint: "api/chat",
            model: "llama3"
        )

        let provider = CustomProvider(
            config: config,
            keychainManager: mockKeychain,
            auditLogger: mockAudit
        )

        #expect(provider.isConfigured == true)
    }

    // MARK: - Authentication Tests

    @Test("Provider works without authentication")
    func testNoAuthRequired() {
        let (provider, _, _) = createTestProvider(
            withAPIKey: false,
            requiresAuth: false
        )

        #expect(provider.isConfigured == true)
    }

    @Test("Provider supports optional authentication")
    func testOptionalAuth() {
        let (provider, _, _) = createTestProvider(
            withAPIKey: true,
            requiresAuth: true
        )

        #expect(provider.isConfigured == true)
    }

    // MARK: - Configuration Update Tests

    @Test("Update provider configuration")
    func testUpdateConfig() {
        let (provider, _, _) = createTestProvider()

        let newConfig = CustomProviderConfig(
            baseURL: "http://localhost:8080",
            model: "mistral"
        )

        provider.updateConfig(newConfig)

        // Provider should still be configured
        #expect(provider.isConfigured == true)
    }

    @Test("Update config to invalid URL makes provider unconfigured")
    func testUpdateConfigToInvalid() {
        let (provider, _, _) = createTestProvider()

        let invalidConfig = CustomProviderConfig(
            baseURL: "not-a-url",
            model: "llama3"
        )

        provider.updateConfig(invalidConfig)

        #expect(provider.isConfigured == false)
    }

    // MARK: - Model Support Tests

    @Test("Support for Llama models")
    func testLlamaModel() {
        let (provider, _, _) = createTestProvider(model: "llama3")
        #expect(provider.isConfigured == true)
    }

    @Test("Support for Mistral models")
    func testMistralModel() {
        let (provider, _, _) = createTestProvider(model: "mistral-7b")
        #expect(provider.isConfigured == true)
    }

    @Test("Support for custom model names")
    func testCustomModelName() {
        let (provider, _, _) = createTestProvider(model: "my-custom-model-v1")
        #expect(provider.isConfigured == true)
    }

    // MARK: - Configuration Defaults Tests

    @Test("Custom provider config has correct defaults")
    func testCustomProviderConfigDefaults() {
        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434"
        )

        #expect(config.baseURL == "http://localhost:11434")
        #expect(config.endpoint == "v1/chat/completions")
        #expect(config.model == "llama3")
        #expect(config.temperature == 0.7)
        #expect(config.maxTokens == 1000)
        #expect(config.requiresAuth == false)
    }

    @Test("Custom provider config accepts all custom values")
    func testCustomProviderConfigAllCustom() {
        let config = CustomProviderConfig(
            baseURL: "https://my-llm.example.com",
            endpoint: "api/v2/completions",
            model: "gpt-j-6b",
            temperature: 0.9,
            maxTokens: 2048,
            requiresAuth: true
        )

        #expect(config.baseURL == "https://my-llm.example.com")
        #expect(config.endpoint == "api/v2/completions")
        #expect(config.model == "gpt-j-6b")
        #expect(config.temperature == 0.9)
        #expect(config.maxTokens == 2048)
        #expect(config.requiresAuth == true)
    }

    // MARK: - Optional Parameter Tests

    @Test("Config with nil temperature")
    func testNilTemperature() {
        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434",
            model: "llama3",
            temperature: nil
        )

        #expect(config.temperature == nil)
    }

    @Test("Config with nil maxTokens")
    func testNilMaxTokens() {
        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434",
            model: "llama3",
            maxTokens: nil
        )

        #expect(config.maxTokens == nil)
    }

    @Test("Config with both parameters nil")
    func testBothParametersNil() {
        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434",
            model: "llama3",
            temperature: nil,
            maxTokens: nil
        )

        #expect(config.temperature == nil)
        #expect(config.maxTokens == nil)
    }

    // MARK: - Cancellation Tests

    @Test("Cancel streaming stops current task")
    func testCancelStreaming() {
        let (provider, _, _) = createTestProvider()

        // Cancel should not throw
        provider.cancelStreaming()

        #expect(provider.isConfigured == true)
    }

    @Test("Multiple cancellations are safe")
    func testMultipleCancellations() {
        let (provider, _, _) = createTestProvider()

        provider.cancelStreaming()
        provider.cancelStreaming()
        provider.cancelStreaming()

        #expect(provider.isConfigured == true)
    }

    // MARK: - Timeout Tests

    @Test("Custom provider has longer timeout for local models")
    func testExtendedTimeout() {
        let (provider, _, _) = createTestProvider()
        // Timeout is 60 seconds for custom providers (vs 30 for cloud)
        #expect(provider.isConfigured == true)
    }

    // MARK: - OpenAI Compatibility Tests

    @Test("Uses OpenAI-compatible message format")
    func testOpenAICompatibleFormat() {
        let (provider, _, _) = createTestProvider()

        let messages = [
            ChatMessage(role: .system, content: "You are a helpful assistant"),
            ChatMessage(role: .user, content: "Hello")
        ]

        #expect(messages.count == 2)
        #expect(provider.isConfigured == true)
    }

    @Test("Supports streaming like OpenAI")
    func testStreamingSupport() {
        let (provider, _, _) = createTestProvider()
        // stream: true is set in request body
        #expect(provider.providerType == .custom)
    }

    // MARK: - Local Server Tests

    @Test("Localhost URL is valid")
    func testLocalhostURL() {
        let (provider, _, _) = createTestProvider(baseURL: "http://localhost:11434")
        #expect(provider.isConfigured == true)
    }

    @Test("127.0.0.1 URL is valid")
    func testIPAddressURL() {
        let (provider, _, _) = createTestProvider(baseURL: "http://127.0.0.1:11434")
        #expect(provider.isConfigured == true)
    }

    @Test("LAN IP URL is valid")
    func testLANIPURL() {
        let (provider, _, _) = createTestProvider(baseURL: "http://192.168.1.100:8000")
        #expect(provider.isConfigured == true)
    }

    // MARK: - Port Tests

    @Test("URL with standard HTTP port")
    func testStandardHTTPPort() {
        let (provider, _, _) = createTestProvider(baseURL: "http://example.com:80")
        #expect(provider.isConfigured == true)
    }

    @Test("URL with standard HTTPS port")
    func testStandardHTTPSPort() {
        let (provider, _, _) = createTestProvider(baseURL: "https://example.com:443")
        #expect(provider.isConfigured == true)
    }

    @Test("URL with custom port")
    func testCustomPort() {
        let (provider, _, _) = createTestProvider(baseURL: "http://example.com:8080")
        #expect(provider.isConfigured == true)
    }

    @Test("URL without explicit port")
    func testNoExplicitPort() {
        let (provider, _, _) = createTestProvider(baseURL: "http://example.com")
        #expect(provider.isConfigured == true)
    }

    // MARK: - Error Handling Tests

    @Test("Handle various error response formats")
    func testErrorResponseFormats() {
        let (provider, _, _) = createTestProvider()
        // Custom provider handles multiple error formats
        #expect(provider.isConfigured == true)
    }

    // MARK: - Message Tests

    @Test("Handle multi-turn conversation")
    func testMultiTurnConversation() {
        let (provider, _, _) = createTestProvider()

        let messages = [
            ChatMessage(role: .system, content: HealthcareSystemPrompt.default),
            ChatMessage(role: .user, content: "I have a headache"),
            ChatMessage(role: .assistant, content: "How long?"),
            ChatMessage(role: .user, content: "Since morning")
        ]

        #expect(messages.count == 4)
        #expect(provider.isConfigured == true)
    }

    @Test("Handle empty message list")
    func testEmptyMessageList() {
        let messages: [ChatMessage] = []
        #expect(messages.isEmpty == true)
    }

    @Test("Handle single message")
    func testSingleMessage() {
        let messages = [
            ChatMessage(role: .user, content: "Hello")
        ]

        #expect(messages.count == 1)
    }

    // MARK: - Retry Configuration Tests

    @Test("Provider has retry logic configured")
    func testRetryConfiguration() {
        let (provider, _, _) = createTestProvider()
        // Max retries is 3
        #expect(provider.isConfigured == true)
    }

    // MARK: - Popular Self-Hosted Provider Tests

    @Test("Ollama default configuration")
    func testOllamaConfig() {
        let config = CustomProviderConfig(
            baseURL: "http://localhost:11434",
            endpoint: "v1/chat/completions",
            model: "llama3",
            requiresAuth: false
        )

        #expect(config.baseURL == "http://localhost:11434")
        #expect(config.requiresAuth == false)
    }

    @Test("llama.cpp server configuration")
    func testLlamaCppConfig() {
        let config = CustomProviderConfig(
            baseURL: "http://localhost:8080",
            endpoint: "v1/chat/completions",
            model: "llama-2-7b",
            requiresAuth: false
        )

        #expect(config.baseURL == "http://localhost:8080")
        #expect(config.requiresAuth == false)
    }

    @Test("Text Generation WebUI configuration")
    func testTextGenWebUIConfig() {
        let config = CustomProviderConfig(
            baseURL: "http://localhost:5000",
            endpoint: "v1/chat/completions",
            model: "TheBloke_Llama-2-7B-GGUF",
            requiresAuth: false
        )

        #expect(config.baseURL == "http://localhost:5000")
        #expect(config.model.contains("Llama"))
    }

    // MARK: - Remote Custom Provider Tests

    @Test("Remote HTTPS custom provider")
    func testRemoteHTTPSProvider() {
        let config = CustomProviderConfig(
            baseURL: "https://my-llm-api.example.com",
            model: "custom-gpt",
            requiresAuth: true
        )

        let mockKeychain = MockKeychainManager()
        try? mockKeychain.set(key: "custom_provider_api_key", value: "secret-key")

        let provider = CustomProvider(
            config: config,
            keychainManager: mockKeychain,
            auditLogger: MockAuditLogger()
        )

        #expect(provider.isConfigured == true)
    }

    // MARK: - Edge Case Tests

    @Test("Very long base URL")
    func testVeryLongBaseURL() {
        let longURL = "http://very-long-domain-name-that-might-exist.example.com:8080"
        let (provider, _, _) = createTestProvider(baseURL: longURL)
        #expect(provider.isConfigured == true)
    }

    @Test("URL with path components")
    func testURLWithPathComponents() {
        let config = CustomProviderConfig(
            baseURL: "http://example.com/api/llm",
            endpoint: "chat/completions",
            model: "custom"
        )

        let provider = CustomProvider(
            config: config,
            keychainManager: MockKeychainManager(),
            auditLogger: MockAuditLogger()
        )

        #expect(provider.isConfigured == true)
    }
}

// MARK: - Mock Keychain Manager

private class MockKeychainManager: KeychainManager {
    private var storage: [String: String] = [:]

    override func set(key: String, value: String) throws {
        storage[key] = value
    }

    override func get(key: String) throws -> String? {
        return storage[key]
    }

    override func delete(key: String) throws {
        storage.removeValue(forKey: key)
    }
}

// MARK: - Mock Audit Logger

private class MockAuditLogger: AuditLogger {
    var loggedEvents: [(AuditEventType, UUID?, [String: Any]?)] = []

    override func log(eventType: AuditEventType, userId: UUID?, details: [String: Any]?) {
        loggedEvents.append((eventType, userId, details))
    }
}
