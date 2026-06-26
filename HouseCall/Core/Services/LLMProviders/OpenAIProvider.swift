//
//  OpenAIProvider.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  OpenAI GPT provider implementation with streaming support
//

import Foundation

/// OpenAI GPT provider implementation
class OpenAIProvider: LLMProvider {
    // MARK: - Properties

    let providerType: LLMProviderType = .openai

    private let keychainManager: KeychainManager
    private let auditLogger: AuditLogger

    private var currentTask: URLSessionDataTask?
    /// Dedicated session created per streaming request (URLSession.shared does not
    /// support per-request delegates).  Stored so `cancelStreaming()` can invalidate it.
    private var streamingSession: URLSession?

    /// Configuration for OpenAI requests
    private var config: OpenAIConfig

    /// OpenAI API endpoint
    private let baseURL = "https://api.openai.com/v1/chat/completions"

    /// Request timeout in seconds
    private let timeout: TimeInterval = 30.0

    /// Maximum retry attempts for transient errors
    private let maxRetries = 3

    // MARK: - Initialization

    init(
        config: OpenAIConfig = OpenAIConfig(),
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
        maxTokensOverride: Int? = nil,
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
            maxTokensOverride: maxTokensOverride,
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
        return try? keychainManager.get(key: "openai_api_key")
    }

    private func performRequestWithRetry(
        messages: [ChatMessage],
        apiKey: String,
        maxTokensOverride: Int? = nil,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void,
        retryCount: Int = 0
    ) async throws {
        do {
            try await performRequest(
                messages: messages,
                apiKey: apiKey,
                maxTokensOverride: maxTokensOverride,
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
                    maxTokensOverride: maxTokensOverride,
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
        maxTokensOverride: Int? = nil,
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
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Build request body
        let requestBody = buildRequestBody(messages: messages, maxTokensOverride: maxTokensOverride)
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Create a fresh SSEParser per request to isolate parser state across
        // concurrent or back-to-back requests.
        let requestParser = SSEParser()

        let streamingDelegate = StreamingURLSessionDelegate(
            sseParser: requestParser,
            onChunk: onChunk,
            onComplete: onComplete
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

    private func buildRequestBody(messages: [ChatMessage], maxTokensOverride: Int? = nil) -> [String: Any] {
        // Convert ChatMessages to OpenAI format
        let openAIMessages = messages.map { message in
            return [
                "role": message.role.rawValue,
                "content": message.content
            ]
        }

        return [
            "model": config.model,
            "messages": openAIMessages,
            "temperature": config.temperature,
            "max_tokens": maxTokensOverride ?? config.maxTokens,
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
                // Try to extract retry-after from error message or headers
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

// MARK: - OpenAI Configuration

struct OpenAIConfig: Codable {
    var model: String
    var temperature: Double
    var maxTokens: Int

    init(
        model: String = "gpt-4",
        temperature: Double = 0.7,
        maxTokens: Int = 1000
    ) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
    }
}

// MARK: - Streaming URLSession Delegate

/// URLSession delegate for handling streaming responses
class StreamingURLSessionDelegate: NSObject, URLSessionDataDelegate {
    private let sseParser: SSEParser
    private let onChunk: (String) -> Void
    private let onComplete: (Result<String, LLMError>) -> Void
    private var fullResponse = ""
    /// Guards against double-firing onComplete (e.g. [DONE] arrives then didCompleteWithError fires).
    private var hasCompleted = false

    init(
        sseParser: SSEParser,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) {
        self.sseParser = sseParser
        self.onChunk = onChunk
        self.onComplete = onComplete
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

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Parse SSE events as they arrive
        sseParser.parse(data: data) { [weak self] event in
            guard let self = self else { return }

            // Check for completion marker
            if event.isComplete {
                self.fireComplete(.success(self.fullResponse))
                return
            }

            // Extract content from OpenAI format
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
            // Normal task completion; the [DONE] marker should have already fired
            // onComplete via didReceive(_:data:).  If the server closed the stream
            // without [DONE] (non-standard), fire it here as a fallback.
            fireComplete(.success(fullResponse))
        }
    }
}
