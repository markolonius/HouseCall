//
//  MarkdownText.swift
//  HouseCall
//
//  Lightweight in-house Markdown renderer for assistant chat bubbles.
//  Handles ATX headings, paragraphs, unordered/ordered lists, fenced code
//  blocks, and inline Markdown (bold, italic, inline code, links) via
//  AttributedString. No third-party dependencies.
//
//  Use for ASSISTANT messages only — user messages stay plain Text.
//

import SwiftUI

// MARK: - Block Model

/// A parsed Markdown block element.
private enum MarkdownBlock {
    case heading(level: Int, text: String)
    case paragraph(text: String)
    case unorderedItem(indent: Int, text: String)
    case orderedItem(number: Int, indent: Int, text: String)
    case codeBlock(language: String?, lines: [String])
}

// MARK: - Parser

/// Converts a raw Markdown string into an ordered list of block elements.
///
/// Pure function — no mutable state. Memoization is the caller's responsibility
/// (see `MarkdownText.cached` for the view-scoped cache).
///
/// Safe with partial/unterminated Markdown that arrives during streaming:
/// an unclosed fence or incomplete inline span is treated as best-effort
/// plain text rather than crashing or producing garbage output.
private struct MarkdownParser {

    static func parse(_ content: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        var pendingLines: [String] = []

        // Accumulate pending paragraph lines into a block and reset.
        func flushParagraph() {
            guard !pendingLines.isEmpty else { return }
            // Join with space: a single line-break in Markdown source is a soft
            // wrap, not a paragraph break.
            let text = pendingLines.joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                blocks.append(.paragraph(text: text))
            }
            pendingLines = []
        }

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // ── Fenced code block ──────────────────────────────────────────
            if trimmed.hasPrefix("```") {
                flushParagraph()
                // Optional language identifier on the opening fence line.
                let hint = String(trimmed.dropFirst(3))
                    .trimmingCharacters(in: .whitespaces)
                let language: String? = hint.isEmpty ? nil : hint
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let codeTrimmed = lines[i].trimmingCharacters(in: .whitespaces)
                    // A closing fence is a line of only backticks (≥ 3) with
                    // no language identifier.
                    if codeTrimmed.hasPrefix("```") &&
                       codeTrimmed.dropFirst(3)
                           .trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }
                // Append even if the fence was never closed (streaming safety).
                blocks.append(.codeBlock(language: language, lines: codeLines))
                continue
            }

            // ── ATX heading ───────────────────────────────────────────────
            if let headingBlock = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(headingBlock)
                i += 1
                continue
            }

            // ── Unordered list item ───────────────────────────────────────
            if let ulBlock = parseUnorderedItem(line) {
                flushParagraph()
                blocks.append(ulBlock)
                i += 1
                continue
            }

            // ── Ordered list item ─────────────────────────────────────────
            if let olBlock = parseOrderedItem(line) {
                flushParagraph()
                blocks.append(olBlock)
                i += 1
                continue
            }

            // ── Blank line: paragraph break ───────────────────────────────
            if trimmed.isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            // ── Paragraph continuation line ───────────────────────────────
            pendingLines.append(trimmed)
            i += 1
        }

        flushParagraph()
        return blocks
    }

    // MARK: Heading

    private static func parseHeading(_ trimmedLine: String) -> MarkdownBlock? {
        var level = 0
        for ch in trimmedLine {
            guard ch == "#" else { break }
            level += 1
        }
        guard level >= 1, level <= 6 else { return nil }
        let afterHashes = trimmedLine.dropFirst(level)
        // There must be a space after the hashes (or the heading text is empty).
        guard afterHashes.isEmpty || afterHashes.first == " " else { return nil }
        let text = afterHashes.trimmingCharacters(in: .whitespaces)
        return .heading(level: level, text: text)
    }

    // MARK: Unordered list item

    private static func parseUnorderedItem(_ line: String) -> MarkdownBlock? {
        var idx = line.startIndex
        var spaces = 0
        while idx < line.endIndex, line[idx] == " " {
            spaces += 1
            idx = line.index(after: idx)
        }
        let rest = line[idx...]
        guard !rest.isEmpty else { return nil }
        let marker: String
        if rest.hasPrefix("- ")      { marker = "- " }
        else if rest.hasPrefix("* ") { marker = "* " }
        else if rest.hasPrefix("+ ") { marker = "+ " }
        else { return nil }
        let text = String(rest.dropFirst(marker.count))
        return .unorderedItem(indent: spaces / 2, text: text)
    }

    // MARK: Ordered list item

    private static func parseOrderedItem(_ line: String) -> MarkdownBlock? {
        var idx = line.startIndex
        var spaces = 0
        while idx < line.endIndex, line[idx] == " " {
            spaces += 1
            idx = line.index(after: idx)
        }
        let rest = line[idx...]
        // Consume leading digits.
        var digits = ""
        var dIdx = rest.startIndex
        while dIdx < rest.endIndex, rest[dIdx].isNumber {
            digits.append(rest[dIdx])
            dIdx = rest.index(after: dIdx)
        }
        guard !digits.isEmpty, dIdx < rest.endIndex else { return nil }
        guard rest[dIdx...].hasPrefix(". ") else { return nil }
        let number = Int(digits) ?? 1
        let text = String(rest[dIdx...].dropFirst(2))
        return .orderedItem(number: number, indent: spaces / 2, text: text)
    }
}

// MARK: - MarkdownText View

/// Renders a raw Markdown `String` as formatted SwiftUI content.
///
/// Block-level elements (headings, lists, code blocks, paragraphs) are
/// composed as a vertical stack. Inline elements (bold, italic, inline code,
/// links) within each block are rendered via `AttributedString(markdown:)`,
/// which falls back to plain text if parsing throws.
///
/// Designed for use with ASSISTANT messages only. Partial/unterminated
/// Markdown (as arrives during SSE streaming) degrades gracefully — never
/// crashes, never exposes raw Markdown symbols beyond what the LLM wrote.
struct MarkdownText: View {
    let content: String

    /// View-scoped parse memo. Holds the most-recently-parsed `(content, blocks)`
    /// pair. Released when this view is torn down — decrypted message text is
    /// never retained beyond the view's lifetime (HIPAA: PHI-in-memory scope
    /// matches `decryptedContent` in `MessageBubbleView`).
    @State private var cached: (content: String, blocks: [MarkdownBlock])? = nil

    var body: some View {
        // Read-only access to @State — no mutation during view evaluation, so no
        // "Modifying state during view update" warning.
        // Falls back to a direct parse when the cache is cold (first render before
        // onAppear fires). Each distinct streaming chunk causes one parse; identical
        // re-renders (same content) return the cached result immediately.
        let blocks = (cached?.content == content)
            ? cached!.blocks
            : MarkdownParser.parse(content)

        VStack(alignment: .leading, spacing: 4) {
            ForEach(blocks.indices, id: \.self) { i in
                blockView(for: blocks[i])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // VoiceOver fix: without this, each block (heading, paragraph, list
        // item, code block) is a separate accessibility element and VoiceOver
        // reads them one by one, breaking the flow of the message.
        // .ignore suppresses child elements; the single label below provides
        // a clean plain-text reading of the full assistant message with all
        // Markdown markers stripped (no "pound pound", "star star", backticks).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.plainText(from: blocks))
        // Populate the cache after the first render and whenever content grows
        // (streaming). Mutations happen in lifecycle callbacks — never inside body.
        .onAppear {
            cached = (content, MarkdownParser.parse(content))
        }
        .onChange(of: content) {
            cached = (content, MarkdownParser.parse(content))
        }
    }

    // MARK: Block Rendering

    @ViewBuilder
    private func blockView(for block: MarkdownBlock) -> some View {
        switch block {

        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(for: level))
                .fontWeight(.bold)
                .padding(.top, level <= 2 ? 4 : 2)
                .padding(.bottom, 2)

        case .paragraph(let text):
            inlineText(text)
                .font(.body)

        case .unorderedItem(let indent, let text):
            HStack(alignment: .top, spacing: 6) {
                Text("•")
                    .font(.body)
                inlineText(text)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(max(indent, 0)) * 16)

        case .orderedItem(let number, let indent, let text):
            HStack(alignment: .top, spacing: 6) {
                Text("\(number).")
                    .font(.body)
                    .monospacedDigit()
                inlineText(text)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(max(indent, 0)) * 16)

        case .codeBlock(_, let lines):
            // Code blocks are rendered monospaced in a subtle background.
            // No Markdown parsing inside — content is treated as literal text.
            Text(lines.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray4))
                .cornerRadius(6)
        }
    }

    // MARK: Inline Rendering

    /// Renders `text` with inline Markdown via `AttributedString`.
    /// If `AttributedString(markdown:)` throws (e.g. malformed or partial
    /// input during streaming), falls back to plain `Text` — never crashes.
    @ViewBuilder
    private func inlineText(_ text: String) -> some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            Text(attributed)
        } else {
            Text(text)
        }
    }

    // MARK: Fonts

    private func headingFont(for level: Int) -> Font {
        switch level {
        case 1:  return .title2
        case 2:  return .title3
        case 3:  return .headline
        case 4:  return .subheadline   // bold via call-site .fontWeight(.bold)
        case 5:  return .footnote      // visually smaller than h4
        default: return .caption       // level 6 — smallest heading
        }
    }

    // MARK: - Accessibility

    /// Converts already-parsed Markdown blocks into a single plain-text
    /// string for VoiceOver. All block-level markers (#, -, *, 1., fences)
    /// and inline markers (**bold**, *italic*, `code`, [link](url)) are
    /// stripped so the screen reader speaks clean prose — not markup symbols.
    ///
    /// PHI note: the returned string contains message content. That is
    /// correct — VoiceOver is on-device display, equivalent to reading the
    /// visible text. Nothing here is logged, printed, or sent to any service.
    private static func plainText(from blocks: [MarkdownBlock]) -> String {
        blocks
            .compactMap { block -> String? in
                switch block {
                case .heading(_, let text):
                    return stripInlineMarkdown(text)
                case .paragraph(let text):
                    return stripInlineMarkdown(text)
                case .unorderedItem(_, let text):
                    return stripInlineMarkdown(text)
                case .orderedItem(_, _, let text):
                    return stripInlineMarkdown(text)
                case .codeBlock(_, let lines):
                    // Code content is already literal text — no inline markers.
                    let joined = lines.joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    return joined.isEmpty ? nil : joined
                }
            }
            .filter { !$0.isEmpty }
            .reduce("") { acc, text in
                guard !acc.isEmpty else { return text }
                // If the previous block already ends with terminal punctuation
                // (.  !  ?) don't prepend another period — use a plain space.
                let terminalPunct: [Character] = [".", "!", "?"]
                let sep = acc.last.map { terminalPunct.contains($0) } == true
                    ? " " : ". "
                return acc + sep + text
            }
    }

    // Compiled once and reused across all stripInlineMarkdown calls.
    // linkRegex:        complete [text](url)  → text
    // partialLinkRegex: dangling [text](url   → text  (no closing paren, end of string)
    private static let linkRegex = try? NSRegularExpression(
        pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let partialLinkRegex = try? NSRegularExpression(
        pattern: #"\[([^\]]*)\]\([^)]*$"#)

    /// Strips common inline Markdown markers from `text`.
    /// Order matters: remove `**`/`__` (bold) before `*`/`_` (italic) so that
    /// bold markers do not leave stray single-character residue.
    ///   **bold**    → bold
    ///   *italic*    → italic
    ///   `code`      → code
    ///   [text](url) → text
    private static func stripInlineMarkdown(_ text: String) -> String {
        var s = text
        // Bold markers first (two-char sequences).
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        // Italic markers (remaining single * / _ after bold pass).
        s = s.replacingOccurrences(of: "*", with: "")
        s = s.replacingOccurrences(of: "_", with: "")
        // Inline code backticks.
        s = s.replacingOccurrences(of: "`", with: "")
        // Complete links: [text](url) → text.
        if let regex = Self.linkRegex {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range,
                                               withTemplate: "$1")
        }
        // Partial-streamed link: [text](url with no closing paren at end of
        // string → text. Keeps mid-stream VoiceOver output clean.
        if let regex = Self.partialLinkRegex {
            let range = NSRange(s.startIndex..., in: s)
            s = regex.stringByReplacingMatches(in: s, range: range,
                                               withTemplate: "$1")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Preview

#Preview("Markdown rendering") {
    ScrollView {
        MarkdownText(content: """
        ## Symptom Summary

        Based on your description, here are the key points:

        - **Fever** above 38°C for more than two days
        - *Fatigue* and general malaise
        - Mild sore throat

        ### What to Watch For

        1. Temperature rising above **39.5°C**
        2. Difficulty breathing
        3. Rash or skin changes

        ```
        Normal temp range: 36.1 – 37.2°C
        Fever threshold:   ≥ 38.0°C
        ```

        Please consult a healthcare provider if symptoms worsen.
        """)
        .padding()
    }
}
