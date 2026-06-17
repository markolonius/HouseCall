//
//  MarkdownTextTests.swift
//  HouseCallTests
//
//  Tests for MarkdownParser (block parsing) and MarkdownText accessibility
//  helpers (plainText / stripInlineMarkdown).
//
//  Spec guard: "Render assistant messages as Markdown" and
//  "VoiceOver reads the formatted content without exposing markup symbols"
//  — openspec/changes/update-patient-chat-ux/specs/ai-chat-interface/spec.md
//

import Testing
import Foundation
@testable import HouseCall

// MARK: - Block Parsing

struct MarkdownParserTests {

    // MARK: Headings

    @Test("ATX H1 parses to heading level 1 with correct text")
    func testH1() {
        let blocks = MarkdownParser.parse("# Hello World")
        #expect(blocks.count == 1)
        #expect(blocks[0] == .heading(level: 1, text: "Hello World"))
    }

    @Test("ATX H2 through H6 parse to correct levels")
    func testH2ToH6() {
        let inputs: [(String, Int)] = [
            ("## Two",    2),
            ("### Three", 3),
            ("#### Four", 4),
            ("##### Five", 5),
            ("###### Six", 6),
        ]
        for (markdown, expectedLevel) in inputs {
            let blocks = MarkdownParser.parse(markdown)
            #expect(blocks.count == 1, "expected 1 block for: \(markdown)")
            if case .heading(let level, _) = blocks[0] {
                #expect(level == expectedLevel)
            } else {
                Issue.record("expected .heading for: \(markdown)")
            }
        }
    }

    @Test("Heading text is trimmed and correct")
    func testHeadingText() {
        let blocks = MarkdownParser.parse("## Symptom Summary")
        #expect(blocks == [.heading(level: 2, text: "Symptom Summary")])
    }

    @Test("H7+ is not a heading — treated as paragraph")
    func testH7IsParagraph() {
        let blocks = MarkdownParser.parse("####### Not A Heading")
        // Seven hashes: not a valid ATX heading (max is 6)
        #expect(blocks.count == 1)
        if case .paragraph = blocks[0] { } else {
            Issue.record("expected .paragraph for ####### line")
        }
    }

    @Test("Hash without space is not a heading — treated as paragraph")
    func testHashWithoutSpaceIsParagraph() {
        let blocks = MarkdownParser.parse("#NoSpace")
        #expect(blocks.count == 1)
        if case .paragraph = blocks[0] { } else {
            Issue.record("expected .paragraph for '#NoSpace'")
        }
    }

    // MARK: Unordered Lists

    @Test("Dash marker produces unorderedItem")
    func testUnorderedDash() {
        let blocks = MarkdownParser.parse("- Apple")
        #expect(blocks == [.unorderedItem(indent: 0, text: "Apple")])
    }

    @Test("Asterisk marker produces unorderedItem")
    func testUnorderedAsterisk() {
        let blocks = MarkdownParser.parse("* Apple")
        #expect(blocks == [.unorderedItem(indent: 0, text: "Apple")])
    }

    @Test("Plus marker produces unorderedItem")
    func testUnorderedPlus() {
        let blocks = MarkdownParser.parse("+ Apple")
        #expect(blocks == [.unorderedItem(indent: 0, text: "Apple")])
    }

    @Test("Multiple unordered items parse in order")
    func testMultipleUnorderedItems() {
        let md = "- First\n- Second\n- Third"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .unorderedItem(indent: 0, text: "First"))
        #expect(blocks[1] == .unorderedItem(indent: 0, text: "Second"))
        #expect(blocks[2] == .unorderedItem(indent: 0, text: "Third"))
    }

    @Test("Indented unordered item has correct indent level")
    func testIndentedUnorderedItem() {
        // Two spaces → indent 1
        let blocks = MarkdownParser.parse("  - Nested")
        #expect(blocks.count == 1)
        if case .unorderedItem(let indent, let text) = blocks[0] {
            #expect(indent == 1)
            #expect(text == "Nested")
        } else {
            Issue.record("expected .unorderedItem")
        }
    }

    // MARK: Ordered Lists

    @Test("Ordered item 1. parses correctly")
    func testOrderedItem() {
        let blocks = MarkdownParser.parse("1. First step")
        #expect(blocks == [.orderedItem(number: 1, indent: 0, text: "First step")])
    }

    @Test("Ordered items preserve their numbers")
    func testOrderedItemNumbers() {
        let md = "1. Alpha\n2. Beta\n3. Gamma"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .orderedItem(number: 1, indent: 0, text: "Alpha"))
        #expect(blocks[1] == .orderedItem(number: 2, indent: 0, text: "Beta"))
        #expect(blocks[2] == .orderedItem(number: 3, indent: 0, text: "Gamma"))
    }

    // MARK: Fenced Code Blocks

    @Test("Fenced code block with no language hint")
    func testFencedCodeNoLanguage() {
        let md = "```\nline one\nline two\n```"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 1)
        #expect(blocks[0] == .codeBlock(language: nil, lines: ["line one", "line two"]))
    }

    @Test("Fenced code block captures language hint")
    func testFencedCodeWithLanguage() {
        let md = "```swift\nlet x = 1\n```"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 1)
        #expect(blocks[0] == .codeBlock(language: "swift", lines: ["let x = 1"]))
    }

    @Test("Code block inner content is verbatim — Markdown markers are not parsed")
    func testFencedCodeIsVerbatim() {
        let md = "```\n**not bold**\n# not heading\n- not a list\n```"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 1)
        if case .codeBlock(_, let lines) = blocks[0] {
            #expect(lines[0] == "**not bold**")
            #expect(lines[1] == "# not heading")
            #expect(lines[2] == "- not a list")
        } else {
            Issue.record("expected .codeBlock")
        }
    }

    @Test("Unterminated fence (streaming safety) — captured as codeBlock without crash")
    func testUnterminatedFence() {
        let md = "```\npartial line"
        // Must not crash; must produce a codeBlock with whatever lines exist.
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 1)
        if case .codeBlock(_, let lines) = blocks[0] {
            #expect(lines == ["partial line"])
        } else {
            Issue.record("expected .codeBlock for unterminated fence")
        }
    }

    // MARK: Paragraphs

    @Test("Plain text parses as paragraph")
    func testPlainTextParagraph() {
        let blocks = MarkdownParser.parse("This is a sentence.")
        #expect(blocks == [.paragraph(text: "This is a sentence.")])
    }

    @Test("Paragraph with inline Markdown preserved as raw text in block")
    func testParagraphWithInlineMarkdown() {
        let md = "Take **two** tablets and call *me* tomorrow."
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 1)
        if case .paragraph(let text) = blocks[0] {
            // The block-level parser stores the raw text (inline rendering happens
            // in the view layer via AttributedString). Assert the text is present.
            #expect(text.contains("two"))
            #expect(text.contains("me"))
        } else {
            Issue.record("expected .paragraph")
        }
    }

    @Test("Blank line between paragraphs creates two separate blocks")
    func testBlankLineSeparatesParagraphs() {
        let md = "First para.\n\nSecond para."
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 2)
        if case .paragraph(let t) = blocks[0] { #expect(t == "First para.") } else {
            Issue.record("expected first .paragraph")
        }
        if case .paragraph(let t) = blocks[1] { #expect(t == "Second para.") } else {
            Issue.record("expected second .paragraph")
        }
    }

    @Test("Soft-wrapped lines (no blank line) merge into one paragraph")
    func testSoftWrapMergesParagraph() {
        let md = "Line one\nLine two"
        let blocks = MarkdownParser.parse(md)
        #expect(blocks.count == 1)
        if case .paragraph(let text) = blocks[0] {
            #expect(text.contains("Line one"))
            #expect(text.contains("Line two"))
        }
    }

    // MARK: Edge & Robustness Cases

    @Test("Empty string produces no blocks")
    func testEmptyString() {
        let blocks = MarkdownParser.parse("")
        #expect(blocks.isEmpty)
    }

    @Test("Whitespace-only string produces no blocks")
    func testWhitespaceOnly() {
        let blocks = MarkdownParser.parse("   \n  \n\t")
        #expect(blocks.isEmpty)
    }

    @Test("Lone hash (# alone) parses as heading with empty text")
    func testLoneHash() {
        // `#` with nothing after it is a valid ATX heading per the parser spec —
        // the text is just empty.
        let blocks = MarkdownParser.parse("#")
        #expect(blocks.count == 1)
        #expect(blocks[0] == .heading(level: 1, text: ""))
    }

    @Test("Unterminated bold (**) does not crash — treated as raw paragraph text")
    func testUnterminatedBold() {
        let blocks = MarkdownParser.parse("Some **unterminated bold")
        #expect(blocks.count == 1)
        if case .paragraph = blocks[0] { } else {
            Issue.record("expected .paragraph for unterminated bold")
        }
    }

    @Test("Mixed document parses all block types correctly")
    func testMixedDocument() {
        let md = """
        ## Overview

        This is a paragraph.

        - Item A
        - Item B

        1. Step one
        2. Step two

        ```swift
        let x = 42
        ```
        """
        let blocks = MarkdownParser.parse(md)
        // heading, paragraph, 2 unordered, 2 ordered, 1 code block = 7 blocks
        #expect(blocks.count == 7)
        #expect(blocks[0] == .heading(level: 2, text: "Overview"))
        #expect(blocks[1] == .paragraph(text: "This is a paragraph."))
        #expect(blocks[2] == .unorderedItem(indent: 0, text: "Item A"))
        #expect(blocks[3] == .unorderedItem(indent: 0, text: "Item B"))
        #expect(blocks[4] == .orderedItem(number: 1, indent: 0, text: "Step one"))
        #expect(blocks[5] == .orderedItem(number: 2, indent: 0, text: "Step two"))
        #expect(blocks[6] == .codeBlock(language: "swift", lines: ["let x = 42"]))
    }
}

// MARK: - VoiceOver / Accessibility Flattening

struct MarkdownTextAccessibilityTests {

    // MARK: stripInlineMarkdown

    @Test("Bold markers stripped: **bold** → bold")
    func testStripBold() {
        let result = MarkdownText.stripInlineMarkdown("**bold**")
        #expect(result == "bold")
    }

    @Test("Double-underscore bold stripped: __bold__ → bold")
    func testStripDoubleUnderscoreBold() {
        let result = MarkdownText.stripInlineMarkdown("__bold__")
        #expect(result == "bold")
    }

    @Test("Italic asterisk stripped: *italic* → italic")
    func testStripItalicAsterisk() {
        let result = MarkdownText.stripInlineMarkdown("*italic*")
        #expect(result == "italic")
    }

    @Test("Italic underscore stripped: _italic_ → italic")
    func testStripItalicUnderscore() {
        let result = MarkdownText.stripInlineMarkdown("_italic_")
        #expect(result == "italic")
    }

    @Test("Inline code stripped: `code` → code")
    func testStripInlineCode() {
        let result = MarkdownText.stripInlineMarkdown("`code`")
        #expect(result == "code")
    }

    @Test("Link reduced to label text: [text](url) → text")
    func testStripLink() {
        let result = MarkdownText.stripInlineMarkdown("[visit here](https://example.com)")
        #expect(result == "visit here")
    }

    @Test("No markup symbols remain in a mixed-inline string")
    func testNoMarkupRemains() {
        let mixed = "**bold** and *italic* with `code` and [link](https://x.com)"
        let result = MarkdownText.stripInlineMarkdown(mixed)
        #expect(!result.contains("*"))
        #expect(!result.contains("_"))
        #expect(!result.contains("`"))
        #expect(!result.contains("["))
        #expect(!result.contains("]"))
        #expect(!result.contains("("))
        #expect(result == "bold and italic with code and link")
    }

    @Test("Empty string returns empty string")
    func testStripEmpty() {
        #expect(MarkdownText.stripInlineMarkdown("") == "")
    }

    // MARK: plainText(from:)

    @Test("Heading block flattens to text without # symbols")
    func testPlainTextHeading() {
        // Parse real Markdown — the parser strips the leading ## from the stored
        // block text, so the VoiceOver label never contains # characters.
        let blocks = MarkdownParser.parse("## Symptom Summary")
        let result = MarkdownText.plainText(from: blocks)
        #expect(!result.contains("#"))
        #expect(result == "Symptom Summary")
    }

    @Test("Paragraph block flattens inline markers")
    func testPlainTextParagraph() {
        let blocks: [MarkdownBlock] = [.paragraph(text: "Take **two** tablets.")]
        let result = MarkdownText.plainText(from: blocks)
        #expect(!result.contains("*"))
        #expect(result.contains("two"))
    }

    @Test("Code block content appears as literal text in plainText")
    func testPlainTextCodeBlock() {
        let blocks: [MarkdownBlock] = [.codeBlock(language: nil, lines: ["x = 1", "y = 2"])]
        let result = MarkdownText.plainText(from: blocks)
        #expect(result.contains("x = 1"))
        #expect(result.contains("y = 2"))
    }

    @Test("Mixed blocks produce single clean string — VoiceOver guard")
    func testPlainTextMixedDocument() {
        // Simulates a real assistant response going through the pipeline:
        // parse → plainText → VoiceOver label.
        let md = """
        ## Diagnosis

        You likely have **seasonal allergies**.

        - Avoid *pollen* outdoors
        - Take `antihistamines` daily
        - See [your doctor](https://example.com)

        ```
        Pollen count: high
        ```
        """
        let blocks = MarkdownParser.parse(md)
        let plain = MarkdownText.plainText(from: blocks)

        // No Markdown markup symbols in the VoiceOver string.
        #expect(!plain.contains("#"))
        #expect(!plain.contains("*"))
        #expect(!plain.contains("_"))
        #expect(!plain.contains("`"))
        #expect(!plain.contains("["))
        #expect(!plain.contains("]("))

        // Meaningful content is present.
        #expect(plain.contains("Diagnosis"))
        #expect(plain.contains("seasonal allergies"))
        #expect(plain.contains("pollen"))
        #expect(plain.contains("antihistamines"))
        #expect(plain.contains("your doctor"))
        #expect(plain.contains("Pollen count"))
    }

    @Test("plainText from empty block list returns empty string")
    func testPlainTextEmpty() {
        let result = MarkdownText.plainText(from: [])
        #expect(result.isEmpty)
    }
}
