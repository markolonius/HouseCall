//
//  LLMProvider.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  HIPAA-compliant LLM provider abstraction layer
//

import Foundation

/// Protocol defining the interface for LLM (Large Language Model) providers
/// Supports multiple providers: OpenAI, Anthropic Claude, and custom/self-hosted models
protocol LLMProvider {
    /// The type of LLM provider (openai, claude, custom)
    var providerType: LLMProviderType { get }

    /// Whether the provider is properly configured with API keys and settings
    var isConfigured: Bool { get }

    /// Stream a completion response from the LLM
    /// - Parameters:
    ///   - messages: Array of chat messages forming the conversation context
    ///   - onChunk: Callback invoked for each streamed token/chunk of text
    ///   - onComplete: Callback invoked when streaming completes (success or error)
    /// - Throws: LLMError if the request cannot be initiated
    func streamCompletion(
        messages: [ChatMessage],
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws

    /// Cancel an ongoing streaming request
    func cancelStreaming()
}

/// Enumeration of supported LLM provider types
enum LLMProviderType: String, CaseIterable, Codable {
    case openai = "openai"
    case claude = "claude"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .openai:
            return "OpenAI"
        case .claude:
            return "Anthropic Claude"
        case .custom:
            return "Custom Provider"
        }
    }
}

/// Represents a single message in a chat conversation
struct ChatMessage: Codable, Equatable {
    let role: MessageRole
    let content: String

    init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// The role of a message sender in a conversation
enum MessageRole: String, Codable, Equatable {
    case system
    case user
    case assistant
}

/// Errors that can occur during LLM provider operations
enum LLMError: Error, LocalizedError {
    case authenticationFailed
    case networkError(Error)
    case invalidResponse
    case rateLimit(retryAfterSeconds: Int?)
    case timeout
    case cancelled
    case providerError(statusCode: Int, message: String)
    case notConfigured
    case invalidConfiguration
    case streamingError(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "API authentication failed. Please check your settings."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Received invalid response from AI service."
        case .rateLimit(let seconds):
            if let seconds = seconds {
                return "Rate limit exceeded. Please wait \(seconds) seconds."
            } else {
                return "Rate limit exceeded. Please try again later."
            }
        case .timeout:
            return "Request timed out. Please try again."
        case .cancelled:
            return "Request was cancelled."
        case .providerError(let statusCode, let message):
            return "Provider error (\(statusCode)): \(message)"
        case .notConfigured:
            return "Provider is not configured. Please add your API key in settings."
        case .invalidConfiguration:
            return "Invalid provider configuration. Please check your settings."
        case .streamingError(let message):
            return "Streaming error: \(message)"
        }
    }

    /// Whether this error should be retried
    var isRetryable: Bool {
        switch self {
        case .networkError, .timeout, .rateLimit:
            return true
        case .authenticationFailed, .notConfigured, .invalidConfiguration, .cancelled:
            return false
        case .providerError(let statusCode, _):
            // Retry on 5xx errors, not on 4xx
            return statusCode >= 500
        case .invalidResponse, .streamingError:
            return false
        }
    }
}

/// Default system prompt for healthcare conversations
struct HealthcareSystemPrompt {
    static let `default` = """
You are a medical AI assistant for HouseCall. Your role is to:
1. Collect patient symptoms and health information
2. Provide preliminary health guidance (NOT diagnoses)
3. Recommend when to seek immediate medical attention
4. Always emphasize that your responses are not a substitute for professional medical advice
5. Be empathetic, clear, and patient-centered

IMPORTANT:
- Never provide definitive diagnoses
- Always recommend consulting a physician for serious symptoms
- Recognize medical emergencies (chest pain, difficulty breathing, severe bleeding, etc.) and advise immediate care
- Maintain patient confidentiality and privacy
- Be supportive and non-judgmental
"""
}
