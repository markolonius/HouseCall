//
//  CustomProvider.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  Custom/self-hosted LLM provider with OpenAI-compatible API support
//

import Foundation

/// Custom provider for self-hosted LLM models (Ollama, llama.cpp, etc.)
/// Uses OpenAI-compatible API format
class CustomProvider: LLMProvider {
    // MARK: - Properties

    let providerType: LLMProviderType = .custom

    private let keychainManager: KeychainManager
    private let auditLogger: AuditLogger

    private var currentTask: URLSessionDataTask?
    private let sseParser = SSEParser()

    /// Configuration for custom provider
    private var config: CustomProviderConfig

    /// Request timeout in seconds
    private let timeout: TimeInterval = 60.0 // Longer timeout for local models

    /// Maximum retry attempts for transient errors
    private let maxRetries = 3

    // MARK: - Initialization

    init(
        config: CustomProviderConfig,
        keychainManager: KeychainManager = .shared,
        auditLogger: AuditLogger = .shared
    ) {
        self.config = config
        self.keychainManager = keychainManager
        self.auditLogger = auditLogger
    }

    // MARK: - LLMProvider Protocol

    var isConfigured: Bool {
        // Custom provider needs at minimum a valid base URL
        guard let url = URL(string: config.baseURL) else {
            return false
        }

        // Validate URL scheme
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    func streamCompletion(
        messages: [ChatMessage],
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        guard isConfigured else {
            throw LLMError.notConfigured
        }

        // Get optional API key
        let apiKey = config.requiresAuth ? getAPIKey() : nil

        // Attempt request with retry logic
        try await performRequestWithRetry(
            messages: messages,
            apiKey: apiKey,
            onChunk: onChunk,
            onComplete: onComplete
        )
    }

    func cancelStreaming() {
        currentTask?.cancel()
        currentTask = nil
        sseParser.reset()
    }

    // MARK: - Public Configuration

    func updateConfig(_ newConfig: CustomProviderConfig) {
        self.config = newConfig
    }

    // MARK: - Private Methods

    private func getAPIKey() -> String? {
        return try? keychainManager.get(key: "custom_provider_api_key")
    }

    private func performRequestWithRetry(
        messages: [ChatMessage],
        apiKey: String?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void,
        retryCount: Int = 0
    ) async throws {
        do {
            try await performRequest(
                messages: messages,
                apiKey: apiKey,
                onChunk: onChunk,
                onComplete: onComplete
            )
        } catch let error as LLMError {
            // Check if we should retry
            if error.isRetryable && retryCount < maxRetries {
                // Exponential backoff: 1s, 2s, 4s
                let delay = pow(2.0, Double(retryCount))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

                // Retry
                try await performRequestWithRetry(
                    messages: messages,
                    apiKey: apiKey,
                    onChunk: onChunk,
                    onComplete: onComplete,
                    retryCount: retryCount + 1
                )
            } else {
                throw error
            }
        }
    }

    private func performRequest(
        messages: [ChatMessage],
        apiKey: String?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        // Construct full endpoint URL
        let fullURL: String
        if config.baseURL.hasSuffix("/") {
            fullURL = config.baseURL + config.endpoint
        } else {
            fullURL = config.baseURL + "/" + config.endpoint
        }

        // Create request
        guard let url = URL(string: fullURL) else {
            throw LLMError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Add authentication if provided
        if let apiKey = apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        // Build request body (OpenAI-compatible format)
        let requestBody = buildRequestBody(messages: messages)
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Reset SSE parser
        sseParser.reset()

        // Track accumulated response
        var fullResponse = ""

        // Create URL session
        let session = URLSession.shared
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }

            // Handle completion
            if let error = error {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                    onComplete(.failure(.cancelled))
                } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                    onComplete(.failure(.timeout))
                } else {
                    onComplete(.failure(.networkError(error)))
                }
                return
            }

            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                guard (200...299).contains(httpResponse.statusCode) else {
                    let error = self.parseHTTPError(
                        statusCode: httpResponse.statusCode,
                        data: data
                    )
                    onComplete(.failure(error))
                    return
                }
            }

            onComplete(.success(fullResponse))
        }

        // Store task for cancellation
        currentTask = task

        // Start streaming request
        task.resume()
    }

    private func buildRequestBody(messages: [ChatMessage]) -> [String: Any] {
        // Convert ChatMessages to OpenAI-compatible format
        let formattedMessages = messages.map { message in
            return [
                "role": message.role.rawValue,
                "content": message.content
            ]
        }

        var body: [String: Any] = [
            "model": config.model,
            "messages": formattedMessages,
            "stream": true
        ]

        // Add optional parameters
        if let temperature = config.temperature {
            body["temperature"] = temperature
        }

        if let maxTokens = config.maxTokens {
            body["max_tokens"] = maxTokens
        }

        return body
    }

    private func parseHTTPError(statusCode: Int, data: Data?) -> LLMError {
        // Try to parse error response
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {

            // Try OpenAI error format
            if let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                return .providerError(statusCode: statusCode, message: message)
            }

            // Try to extract any error message
            if let message = json["message"] as? String {
                return .providerError(statusCode: statusCode, message: message)
            }

            if let error = json["error"] as? String {
                return .providerError(statusCode: statusCode, message: error)
            }
        }

        // Handle specific status codes
        switch statusCode {
        case 401, 403:
            return .authenticationFailed
        case 429:
            return .rateLimit(retryAfterSeconds: nil)
        case 500...599:
            return .providerError(statusCode: statusCode, message: "Server error")
        default:
            return .providerError(statusCode: statusCode, message: "Unknown error")
        }
    }
}

// MARK: - Custom Provider Configuration

struct CustomProviderConfig {
    /// Base URL for the custom provider (e.g., "http://localhost:11434")
    var baseURL: String

    /// API endpoint path (default: "v1/chat/completions" for OpenAI compatibility)
    var endpoint: String

    /// Model name to use
    var model: String

    /// Optional temperature (0.0 - 2.0)
    var temperature: Double?

    /// Optional max tokens
    var maxTokens: Int?

    /// Whether authentication is required
    var requiresAuth: Bool

    init(
        baseURL: String,
        endpoint: String = "v1/chat/completions",
        model: String = "llama3",
        temperature: Double? = 0.7,
        maxTokens: Int? = 1000,
        requiresAuth: Bool = false
    ) {
        self.baseURL = baseURL
        self.endpoint = endpoint
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.requiresAuth = requiresAuth
    }
}

// MARK: - Streaming URLSession Delegate for Custom Provider

/// URLSession delegate for handling custom provider streaming responses
class CustomProviderStreamingDelegate: NSObject, URLSessionDataDelegate {
    private let sseParser: SSEParser
    private let onChunk: (String) -> Void
    private let onComplete: (Result<String, LLMError>) -> Void
    private var fullResponse = ""

    init(
        sseParser: SSEParser,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) {
        self.sseParser = sseParser
        self.onChunk = onChunk
        self.onComplete = onComplete
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Parse SSE events as they arrive (using OpenAI format)
        sseParser.parse(data: data) { [weak self] event in
            guard let self = self else { return }

            // Check for completion marker
            if event.isComplete {
                self.onComplete(.success(self.fullResponse))
                return
            }

            // Extract content from OpenAI-compatible format
            if let content = SSEParser.extractOpenAIContent(from: event) {
                self.fullResponse.append(content)
                self.onChunk(content)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                onComplete(.failure(.cancelled))
            } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                onComplete(.failure(.timeout))
            } else {
                onComplete(.failure(.networkError(error)))
            }
        }
    }
}
