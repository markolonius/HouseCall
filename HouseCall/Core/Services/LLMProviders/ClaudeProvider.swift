//
//  ClaudeProvider.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  Anthropic Claude provider implementation with streaming support
//

import Foundation

/// Anthropic Claude provider implementation
class ClaudeProvider: LLMProvider {
    // MARK: - Properties

    let providerType: LLMProviderType = .claude

    private let keychainManager: KeychainManager
    private let auditLogger: AuditLogger

    private var currentTask: URLSessionDataTask?
    /// Dedicated session created per streaming request (URLSession.shared does not
    /// support per-request delegates).  Stored so `cancelStreaming()` can invalidate it.
    private var streamingSession: URLSession?

    /// Configuration for Claude requests
    private var config: ClaudeConfig

    /// Anthropic API endpoint
    private let baseURL = "https://api.anthropic.com/v1/messages"

    /// API version to use
    private let apiVersion = "2023-06-01"

    /// Request timeout in seconds
    private let timeout: TimeInterval = 30.0

    /// Maximum retry attempts for transient errors
    private let maxRetries = 3

    // MARK: - Initialization

    init(
        config: ClaudeConfig = ClaudeConfig(),
        keychainManager: KeychainManager = .shared,
        auditLogger: AuditLogger = .shared
    ) {
        self.config = config
        self.keychainManager = keychainManager
        self.auditLogger = auditLogger
    }

    // MARK: - LLMProvider Protocol

    var isConfigured: Bool {
        return getAPIKey() != nil
    }

    func streamCompletion(
        messages: [ChatMessage],
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        guard isConfigured else {
            throw LLMError.notConfigured
        }

        guard let apiKey = getAPIKey() else {
            throw LLMError.notConfigured
        }

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
        streamingSession?.invalidateAndCancel()
        streamingSession = nil
    }

    // MARK: - Private Methods

    private func getAPIKey() -> String? {
        return try? keychainManager.get(key: "claude_api_key")
    }

    private func performRequestWithRetry(
        messages: [ChatMessage],
        apiKey: String,
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
        apiKey: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        // Create request
        guard let url = URL(string: baseURL) else {
            throw LLMError.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout

        // Set Claude-specific headers
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        // Build request body
        let requestBody = buildRequestBody(messages: messages)
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Create a fresh SSEParser per request to isolate parser state across
        // concurrent or back-to-back requests.
        let requestParser = SSEParser()

        let streamingDelegate = ClaudeStreamingDelegate(
            sseParser: requestParser,
            onChunk: onChunk,
            onComplete: onComplete,
            onSessionInvalidated: { [weak self] in self?.streamingSession = nil }
        )
        // URLSession.shared does not support per-request delegates; a dedicated session
        // is required so urlSession(_:dataTask:didReceive:) fires incrementally for
        // each SSE chunk instead of once at the end of the response.
        let session = URLSession(configuration: .default, delegate: streamingDelegate, delegateQueue: nil)
        streamingSession = session
        let task = session.dataTask(with: request)
        currentTask = task
        task.resume()
    }

    private func buildRequestBody(messages: [ChatMessage]) -> [String: Any] {
        // Claude API requires separating system messages from conversation messages
        var systemPrompt = HealthcareSystemPrompt.default
        var conversationMessages: [[String: String]] = []

        for message in messages {
            if message.role == .system {
                // Append to system prompt
                systemPrompt += "\n\n" + message.content
            } else {
                // Add to conversation messages
                conversationMessages.append([
                    "role": message.role.rawValue,
                    "content": message.content
                ])
            }
        }

        return [
            "model": config.model,
            "max_tokens": config.maxTokens,
            "temperature": config.temperature,
            "system": systemPrompt,
            "messages": conversationMessages,
            "stream": true
        ]
    }

    private func parseHTTPError(statusCode: Int, data: Data?) -> LLMError {
        // Try to parse error response
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {

            // Check for rate limiting
            if statusCode == 429 {
                return .rateLimit(retryAfterSeconds: 60)
            }

            return .providerError(statusCode: statusCode, message: message)
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

// MARK: - Claude Configuration

struct ClaudeConfig: Codable {
    var model: String
    var temperature: Double
    var maxTokens: Int

    init(
        model: String = "claude-3-5-sonnet-20241022",
        temperature: Double = 0.7,
        maxTokens: Int = 1000
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

// MARK: - Streaming URLSession Delegate for Claude

/// URLSession delegate for handling Claude streaming responses
class ClaudeStreamingDelegate: NSObject, URLSessionDataDelegate {
    private let sseParser: SSEParser
    private let onChunk: (String) -> Void
    private let onComplete: (Result<String, LLMError>) -> Void
    private var fullResponse = ""
    /// Guards against double-firing onComplete (e.g. message_stop arrives then didCompleteWithError fires).
    private var hasCompleted = false
    /// Called when the URLSession becomes invalid so the owning provider can clear its reference.
    private let onSessionInvalidated: (() -> Void)?

    init(
        sseParser: SSEParser,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void,
        onSessionInvalidated: (() -> Void)? = nil
    ) {
        self.sseParser = sseParser
        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onSessionInvalidated = onSessionInvalidated
    }

    /// Fires onComplete exactly once.
    private func fireComplete(_ result: Result<String, LLMError>) {
        guard !hasCompleted else { return }
        hasCompleted = true
        onComplete(result)
    }

    /// Validate the HTTP status code before allowing data to flow through the parser.
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let httpResponse = response as? HTTPURLResponse else {
            completionHandler(.allow)
            return
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let statusCode = httpResponse.statusCode
            let llmError: LLMError
            switch statusCode {
            case 401, 403: llmError = .authenticationFailed
            case 429:
                // Extract Retry-After header (integer seconds per HTTP spec); fall back to 60.
                let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                    .flatMap { Int($0) }
                llmError = .rateLimit(retryAfterSeconds: retryAfter ?? 60)
            case 500...599: llmError = .providerError(statusCode: statusCode, message: "Server error")
            default: llmError = .providerError(statusCode: statusCode, message: "HTTP \(statusCode)")
            }
            fireComplete(.failure(llmError))
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        onSessionInvalidated?()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Parse SSE events as they arrive
        sseParser.parse(data: data) { [weak self] event in
            guard let self = self else { return }

            // Check for completion marker
            if SSEParser.isClaudeComplete(event: event) {
                self.fireComplete(.success(self.fullResponse))
                return
            }

            // Extract content from Claude format
            if let content = SSEParser.extractClaudeContent(from: event) {
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
        defer { session.finishTasksAndInvalidate() }
        if let error = error {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                fireComplete(.failure(.cancelled))
            } else if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorTimedOut {
                fireComplete(.failure(.timeout))
            } else {
                fireComplete(.failure(.networkError(error)))
            }
        } else {
            // Normal task completion; the message_stop event should have already fired
            // onComplete via didReceive(_:data:).  If the server closed the stream
            // without it (non-standard), fire it here as a fallback.
            fireComplete(.success(fullResponse))
        }
    }
}
