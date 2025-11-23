//
//  SSEParserTests.swift
//  HouseCallTests
//
//  Created by Claude Code on 2025-11-23.
//  Tests for Server-Sent Events parser
//

import Testing
import Foundation
@testable import HouseCall

struct SSEParserTests {
    // MARK: - Basic SSE Parsing

    @Test("Parse single SSE event with data field")
    func testParseSingleEvent() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let sseData = "data: Hello World\n\n".data(using: .utf8)!

        parser.parse(data: sseData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].data == "Hello World")
        #expect(receivedEvents[0].isComplete == false)
    }

    @Test("Parse multiple SSE events")
    func testParseMultipleEvents() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let sseData = """
        data: First message

        data: Second message

        data: Third message


        """.data(using: .utf8)!

        parser.parse(data: sseData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 3)
        #expect(receivedEvents[0].data == "First message")
        #expect(receivedEvents[1].data == "Second message")
        #expect(receivedEvents[2].data == "Third message")
    }

    @Test("Parse SSE event with event type")
    func testParseEventWithType() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let sseData = """
        event: message
        data: Hello

        """.data(using: .utf8)!

        parser.parse(data: sseData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].eventType == "message")
        #expect(receivedEvents[0].data == "Hello")
    }

    @Test("Parse SSE event with ID")
    func testParseEventWithID() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let sseData = """
        id: 123
        data: Test message

        """.data(using: .utf8)!

        parser.parse(data: sseData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].id == "123")
        #expect(receivedEvents[0].data == "Test message")
    }

    @Test("Parse [DONE] marker as completion")
    func testParseDoneMarker() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let sseData = "data: [DONE]\n\n".data(using: .utf8)!

        parser.parse(data: sseData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].data == "[DONE]")
        #expect(receivedEvents[0].isComplete == true)
    }

    @Test("Handle partial chunks buffering")
    func testHandlePartialChunks() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        // First chunk (incomplete)
        let chunk1 = "data: Partial mes".data(using: .utf8)!
        parser.parse(data: chunk1) { event in
            receivedEvents.append(event)
        }

        // Should not emit any events yet
        #expect(receivedEvents.count == 0)

        // Second chunk (completes the event)
        let chunk2 = "sage\n\n".data(using: .utf8)!
        parser.parse(data: chunk2) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].data == "Partial message")
    }

    @Test("Skip empty lines and comments")
    func testSkipEmptyLinesAndComments() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let sseData = """
        : This is a comment

        data: Valid message

        """.data(using: .utf8)!

        parser.parse(data: sseData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].data == "Valid message")
    }

    // MARK: - OpenAI Format Parsing

    @Test("Extract OpenAI content from SSE event")
    func testExtractOpenAIContent() throws {
        let jsonData = #"{"choices":[{"delta":{"content":"Hello"}}]}"#
        let event = SSEEvent(data: jsonData)

        let content = SSEParser.extractOpenAIContent(from: event)

        #expect(content == "Hello")
    }

    @Test("Return nil for OpenAI [DONE] event")
    func testOpenAIDoneEvent() throws {
        let event = SSEEvent(data: "[DONE]", isComplete: true)

        let content = SSEParser.extractOpenAIContent(from: event)

        #expect(content == nil)
    }

    @Test("Handle OpenAI event with no content")
    func testOpenAINoContent() throws {
        let jsonData = #"{"choices":[{"delta":{}}]}"#
        let event = SSEEvent(data: jsonData)

        let content = SSEParser.extractOpenAIContent(from: event)

        #expect(content == nil)
    }

    // MARK: - Claude Format Parsing

    @Test("Extract Claude content from content_block_delta event")
    func testExtractClaudeContent() throws {
        let jsonData = #"{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hello"}}"#
        let event = SSEEvent(eventType: "content_block_delta", data: jsonData)

        let content = SSEParser.extractClaudeContent(from: event)

        #expect(content == "Hello")
    }

    @Test("Return nil for non-content Claude events")
    func testClaudeNonContentEvent() throws {
        let jsonData = #"{"type":"message_start"}"#
        let event = SSEEvent(eventType: "message_start", data: jsonData)

        let content = SSEParser.extractClaudeContent(from: event)

        #expect(content == nil)
    }

    @Test("Detect Claude completion event")
    func testClaudeCompletionDetection() throws {
        let event = SSEEvent(eventType: "message_stop", data: "")

        let isComplete = SSEParser.isClaudeComplete(event: event)

        #expect(isComplete == true)
    }

    @Test("Claude incomplete event returns false")
    func testClaudeIncompleteEvent() throws {
        let event = SSEEvent(eventType: "content_block_delta", data: "")

        let isComplete = SSEParser.isClaudeComplete(event: event)

        #expect(isComplete == false)
    }

    // MARK: - Edge Cases

    @Test("Handle multi-line data fields")
    func testMultiLineData() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let sseData = """
        data: Line 1
        data: Line 2
        data: Line 3

        """.data(using: .utf8)!

        parser.parse(data: sseData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].data == "Line 1\nLine 2\nLine 3")
    }

    @Test("Reset parser clears buffer")
    func testResetParser() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        // Add partial data
        let chunk1 = "data: Incomplete".data(using: .utf8)!
        parser.parse(data: chunk1) { event in
            receivedEvents.append(event)
        }

        // Reset
        parser.reset()

        // Add new complete event
        let chunk2 = "data: New message\n\n".data(using: .utf8)!
        parser.parse(data: chunk2) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 1)
        #expect(receivedEvents[0].data == "New message")
    }

    @Test("Handle malformed JSON gracefully")
    func testMalformedJSON() throws {
        let event = SSEEvent(data: "not valid json{")

        let openAIContent = SSEParser.extractOpenAIContent(from: event)
        #expect(openAIContent == nil)

        let claudeEvent = SSEEvent(eventType: "content_block_delta", data: "not valid json{")
        let claudeContent = SSEParser.extractClaudeContent(from: claudeEvent)
        #expect(claudeContent == nil)
    }

    @Test("Handle empty data gracefully")
    func testEmptyData() throws {
        let parser = SSEParser()
        var receivedEvents: [SSEEvent] = []

        let emptyData = Data()
        parser.parse(data: emptyData) { event in
            receivedEvents.append(event)
        }

        #expect(receivedEvents.count == 0)
    }
}
