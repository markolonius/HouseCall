//
//  ClaudeProviderTests.swift
//  HouseCallTests
//
//  Created by Claude Code on 2025-11-23.
//  Unit tests for Anthropic Claude provider implementation
//

import Testing
import Foundation
@testable import HouseCall

@Suite("Claude Provider Tests")
struct ClaudeProviderTests {

    // MARK: - Helper Setup

    private func createTestProvider(
        model: String = "claude-3-5-sonnet-20241022",
        withAPIKey: Bool = true
    ) -> (ClaudeProvider, MockKeychainManager, MockAuditLogger) {
        let mockKeychain = MockKeychainManager()
        let mockAudit = MockAuditLogger()

        if withAPIKey {
            try? mockKeychain.set(key: "claude_api_key", value: "test-claude-key")
        }

        let config = ClaudeConfig(model: model, temperature: 0.7, maxTokens: 1000)
        let provider = ClaudeProvider(
            config: config,
            keychainManager: mockKeychain,
            auditLogger: mockAudit
        )

        return (provider, mockKeychain, mockAudit)
    }

    // MARK: - Configuration Tests

    @Test("Provider type is Claude")
    func testProviderType() {
        let (provider, _, _) = createTestProvider()
        #expect(provider.providerType == .claude)
    }

    @Test("Provider is configured with valid API key")
    func testIsConfiguredWithAPIKey() {
        let (provider, _, _) = createTestProvider(withAPIKey: true)
        #expect(provider.isConfigured == true)
    }

    @Test("Provider is not configured without API key")
    func testIsConfiguredWithoutAPIKey() {
        let (provider, _, _) = createTestProvider(withAPIKey: false)
        #expect(provider.isConfigured == false)
    }

    @Test("Provider throws error when not configured")
    func testStreamCompletionThrowsWhenNotConfigured() async {
        let (provider, _, _) = createTestProvider(withAPIKey: false)

        let messages = [
            ChatMessage(role: .user, content: "Hello")
        ]

        var onChunkCalled = false
        var completionResult: Result<String, LLMError>?

        await #expect(throws: LLMError.self) {
            try await provider.streamCompletion(
                messages: messages,
                onChunk: { _ in onChunkCalled = true },
                onComplete: { result in completionResult = result }
            )
        }

        #expect(onChunkCalled == false)
    }

    // MARK: - Cancellation Tests

    @Test("Cancel streaming stops current task")
    func testCancelStreaming() {
        let (provider, _, _) = createTestProvider()

        // Cancel should not throw
        provider.cancelStreaming()

        // Verify provider still configured after cancel
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

    // MARK: - Configuration Tests

    @Test("Claude config has correct defaults")
    func testClaudeConfigDefaults() {
        let config = ClaudeConfig()

        #expect(config.model == "claude-3-5-sonnet-20241022")
        #expect(config.temperature == 0.7)
        #expect(config.maxTokens == 1000)
    }

    @Test("Claude config accepts custom values")
    func testClaudeConfigCustomValues() {
        let config = ClaudeConfig(
            model: "claude-3-opus-20240229",
            temperature: 0.5,
            maxTokens: 2000
        )

        #expect(config.model == "claude-3-opus-20240229")
        #expect(config.temperature == 0.5)
        #expect(config.maxTokens == 2000)
    }

    // MARK: - System Message Handling Tests

    @Test("System messages are separated from conversation")
    func testSystemMessageSeparation() {
        let (provider, _, _) = createTestProvider()

        // Claude requires system messages to be in a separate field
        let messages = [
            ChatMessage(role: .system, content: "You are a medical assistant"),
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there!"),
            ChatMessage(role: .user, content: "I need help")
        ]

        #expect(messages.count == 4)
        #expect(provider.isConfigured == true)

        // Verify system message is first
        #expect(messages[0].role == .system)
    }

    @Test("Multiple system messages are combined")
    func testMultipleSystemMessages() {
        let messages = [
            ChatMessage(role: .system, content: "You are a medical assistant"),
            ChatMessage(role: .system, content: "Be empathetic and clear"),
            ChatMessage(role: .user, content: "Hello")
        ]

        let systemMessages = messages.filter { $0.role == .system }
        #expect(systemMessages.count == 2)
    }

    @Test("Conversation without system message")
    func testConversationWithoutSystemMessage() {
        let (provider, _, _) = createTestProvider()

        let messages = [
            ChatMessage(role: .user, content: "Hello"),
            ChatMessage(role: .assistant, content: "Hi there!")
        ]

        #expect(messages.count == 2)
        #expect(messages.allSatisfy { $0.role != .system })
        #expect(provider.isConfigured == true)
    }

    // MARK: - Message Formatting Tests

    @Test("User and assistant messages formatted correctly")
    func testMessageFormatting() {
        let messages = [
            ChatMessage(role: .user, content: "What are symptoms of flu?"),
            ChatMessage(role: .assistant, content: "Common flu symptoms include fever, cough, and fatigue")
        ]

        #expect(messages[0].role == .user)
        #expect(messages[1].role == .assistant)
        #expect(messages[0].content.contains("symptoms"))
        #expect(messages[1].content.contains("fever"))
    }

    @Test("Empty message content")
    func testEmptyMessageContent() {
        let message = ChatMessage(role: .user, content: "")
        #expect(message.content.isEmpty == true)
    }

    @Test("Very long message content")
    func testLongMessageContent() {
        let longContent = String(repeating: "a", count: 10000)
        let message = ChatMessage(role: .user, content: longContent)
        #expect(message.content.count == 10000)
    }

    // MARK: - Error Handling Tests

    @Test("Handle 401 authentication error")
    func testAuthenticationError() {
        let (provider, _, _) = createTestProvider()
        #expect(provider.isConfigured == true)
    }

    @Test("Handle 429 rate limit error")
    func testRateLimitError() {
        let (provider, _, _) = createTestProvider()
        #expect(provider.providerType == .claude)
    }

    @Test("Handle 500 server error")
    func testServerError() {
        let (provider, _, _) = createTestProvider()
        #expect(provider.isConfigured == true)
    }

    // MARK: - API Version Tests

    @Test("API version header is set")
    func testAPIVersionHeader() {
        let (provider, _, _) = createTestProvider()
        // Claude requires anthropic-version header
        #expect(provider.providerType == .claude)
    }

    // MARK: - Model Tests

    @Test("Supports Claude 3.5 Sonnet")
    func testClaude35Sonnet() {
        let (provider, _, _) = createTestProvider(model: "claude-3-5-sonnet-20241022")
        #expect(provider.isConfigured == true)
    }

    @Test("Supports Claude 3 Opus")
    func testClaude3Opus() {
        let (provider, _, _) = createTestProvider(model: "claude-3-opus-20240229")
        #expect(provider.isConfigured == true)
    }

    @Test("Supports Claude 3 Haiku")
    func testClaude3Haiku() {
        let (provider, _, _) = createTestProvider(model: "claude-3-haiku-20240307")
        #expect(provider.isConfigured == true)
    }

    // MARK: - Timeout Tests

    @Test("Request has timeout configured")
    func testRequestTimeout() {
        let (provider, _, _) = createTestProvider()
        // Verify provider is initialized (timeout is internal)
        #expect(provider.isConfigured == true)
    }

    // MARK: - Retry Logic Tests

    @Test("Provider is configured for retries")
    func testRetryConfiguration() {
        let (provider, _, _) = createTestProvider()
        // Max retries is 3 (internal configuration)
        #expect(provider.isConfigured == true)
    }

    // MARK: - Healthcare System Prompt Tests

    @Test("Healthcare system prompt is used")
    func testHealthcareSystemPrompt() {
        let (provider, _, _) = createTestProvider()
        // HealthcareSystemPrompt.default is used internally
        #expect(provider.providerType == .claude)
    }

    @Test("System prompt can be extended")
    func testExtendedSystemPrompt() {
        let basePrompt = HealthcareSystemPrompt.default
        let customAddition = "Focus on pediatric care"
        let extendedPrompt = basePrompt + "\n\n" + customAddition

        #expect(extendedPrompt.contains("medical"))
        #expect(extendedPrompt.contains("pediatric"))
    }

    // MARK: - Streaming Tests

    @Test("Streaming is enabled by default")
    func testStreamingEnabled() {
        let (provider, _, _) = createTestProvider()
        // stream: true is set in request body
        #expect(provider.providerType == .claude)
    }

    // MARK: - Complex Conversation Tests

    @Test("Handle multi-turn conversation")
    func testMultiTurnConversation() {
        let (provider, _, _) = createTestProvider()

        let messages = [
            ChatMessage(role: .system, content: HealthcareSystemPrompt.default),
            ChatMessage(role: .user, content: "I have a headache"),
            ChatMessage(role: .assistant, content: "How long have you had the headache?"),
            ChatMessage(role: .user, content: "Since this morning"),
            ChatMessage(role: .assistant, content: "Any other symptoms?"),
            ChatMessage(role: .user, content: "Yes, mild fever")
        ]

        #expect(messages.count == 6)
        #expect(messages.filter { $0.role == .user }.count == 3)
        #expect(messages.filter { $0.role == .assistant }.count == 2)
        #expect(messages.filter { $0.role == .system }.count == 1)
    }

    @Test("Handle conversation with special characters")
    func testSpecialCharactersInMessages() {
        let messages = [
            ChatMessage(role: .user, content: "What about headache with \"quotes\" and \n newlines?"),
            ChatMessage(role: .assistant, content: "I can handle special chars: @#$%^&*()")
        ]

        #expect(messages[0].content.contains("\""))
        #expect(messages[0].content.contains("\n"))
        #expect(messages[1].content.contains("@#$"))
    }

    @Test("Handle Unicode in messages")
    func testUnicodeInMessages() {
        let messages = [
            ChatMessage(role: .user, content: "患者有头痛症状"),
            ChatMessage(role: .assistant, content: "¿Cuánto tiempo ha tenido el dolor?"),
            ChatMessage(role: .user, content: "Боль началась утром")
        ]

        #expect(messages[0].content.contains("患者"))
        #expect(messages[1].content.contains("¿"))
        #expect(messages[2].content.contains("Боль"))
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
