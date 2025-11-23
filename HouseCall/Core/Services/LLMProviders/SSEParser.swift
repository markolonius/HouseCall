//
//  SSEParser.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  Server-Sent Events (SSE) parser for streaming LLM responses
//

import Foundation

/// Parser for Server-Sent Events (SSE) format used by streaming LLM APIs
class SSEParser {
    /// Buffer for incomplete event data
    private var buffer: String = ""

    /// Parse incoming SSE data and extract events
    /// - Parameters:
    ///   - data: Raw data received from the stream
    ///   - onEvent: Callback invoked for each complete SSE event
    func parse(data: Data, onEvent: @escaping (SSEEvent) -> Void) {
        // Convert data to string and append to buffer
        guard let chunk = String(data: data, encoding: .utf8) else {
            return
        }

        buffer.append(chunk)

        // Process all complete events in the buffer
        processBuffer(onEvent: onEvent)
    }

    /// Process buffered data and extract complete events
    private func processBuffer(onEvent: @escaping (SSEEvent) -> Void) {
        // SSE events are separated by double newlines (\n\n or \r\n\r\n)
        let eventDelimiter = "\n\n"

        while let range = buffer.range(of: eventDelimiter) {
            // Extract the event text
            let eventText = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)

            // Parse the event
            if let event = parseEvent(eventText) {
                onEvent(event)
            }
        }
    }

    /// Parse a single SSE event from text
    /// - Parameter eventText: The text of a single SSE event
    /// - Returns: Parsed SSEEvent or nil if invalid
    private func parseEvent(_ eventText: String) -> SSEEvent? {
        var eventType: String?
        var data: String?
        var id: String?

        // Parse event fields (format: "field: value")
        let lines = eventText.components(separatedBy: .newlines)
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Skip empty lines and comments
            if trimmedLine.isEmpty || trimmedLine.hasPrefix(":") {
                continue
            }

            // Parse field: value
            if let colonIndex = trimmedLine.firstIndex(of: ":") {
                let field = String(trimmedLine[..<colonIndex])
                var value = String(trimmedLine[trimmedLine.index(after: colonIndex)...])

                // Remove leading space after colon (per SSE spec)
                if value.hasPrefix(" ") {
                    value.removeFirst()
                }

                switch field {
                case "event":
                    eventType = value
                case "data":
                    // Data fields can appear multiple times; concatenate with newlines
                    if let existingData = data {
                        data = existingData + "\n" + value
                    } else {
                        data = value
                    }
                case "id":
                    id = value
                default:
                    // Ignore unknown fields per SSE spec
                    break
                }
            }
        }

        // Return event if we have data
        if let data = data {
            // Check for [DONE] marker used by OpenAI
            let isDone = data == "[DONE]"
            return SSEEvent(
                eventType: eventType,
                data: data,
                id: id,
                isComplete: isDone
            )
        }

        return nil
    }

    /// Reset the parser's internal buffer
    func reset() {
        buffer = ""
    }
}

/// Represents a single Server-Sent Event
struct SSEEvent {
    /// Optional event type (if specified with "event:" field)
    let eventType: String?

    /// Event data (from "data:" field)
    let data: String

    /// Optional event ID (if specified with "id:" field)
    let id: String?

    /// Whether this event signals completion ([DONE] marker)
    let isComplete: Bool

    init(eventType: String? = nil, data: String, id: String? = nil, isComplete: Bool = false) {
        self.eventType = eventType
        self.data = data
        self.id = id
        self.isComplete = isComplete
    }
}

// MARK: - OpenAI-specific parsing helpers

extension SSEParser {
    /// Extract text content from an OpenAI streaming chunk
    /// - Parameter event: SSE event from OpenAI
    /// - Returns: Extracted text content or nil if not present
    static func extractOpenAIContent(from event: SSEEvent) -> String? {
        // OpenAI format: {"choices":[{"delta":{"content":"text"}}]}
        guard !event.isComplete else { return nil }

        guard let jsonData = event.data.data(using: .utf8) else {
            return nil
        }

        do {
            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let choices = json["choices"] as? [[String: Any]],
               let firstChoice = choices.first,
               let delta = firstChoice["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                return content
            }
        } catch {
            // Invalid JSON, return nil
            return nil
        }

        return nil
    }
}

// MARK: - Anthropic Claude-specific parsing helpers

extension SSEParser {
    /// Extract text content from a Claude streaming chunk
    /// - Parameter event: SSE event from Anthropic Claude
    /// - Returns: Extracted text content or nil if not present
    static func extractClaudeContent(from event: SSEEvent) -> String? {
        guard !event.isComplete else { return nil }

        // Claude uses different event types
        guard let eventType = event.eventType else { return nil }

        // Only process content_block_delta events which contain text
        guard eventType == "content_block_delta" else { return nil }

        guard let jsonData = event.data.data(using: .utf8) else {
            return nil
        }

        do {
            // Claude format: {"type":"content_block_delta","delta":{"type":"text_delta","text":"content"}}
            if let json = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
               let delta = json["delta"] as? [String: Any],
               let text = delta["text"] as? String {
                return text
            }
        } catch {
            return nil
        }

        return nil
    }

    /// Check if Claude event signals completion
    /// - Parameter event: SSE event from Anthropic Claude
    /// - Returns: True if this is a completion event
    static func isClaudeComplete(event: SSEEvent) -> Bool {
        // Claude sends message_stop event when complete
        return event.eventType == "message_stop" || event.isComplete
    }
}
