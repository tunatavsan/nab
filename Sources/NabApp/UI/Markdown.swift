import NabCore
import SwiftUI

/// The block structure chat answers actually use: headings, paragraphs, lists, quotes, code.
enum MarkdownBlock: Hashable {
    case heading(String)
    case paragraph(String)
    case item(marker: String, text: String, level: Int)
    case quote(String)
    case code(String)
    case rule

    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flush() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            paragraph = []
        }

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") {
                    blocks.append(.code(code!.joined(separator: "\n")))
                    code = nil
                } else {
                    code!.append(line)
                }
                continue
            }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            if trimmed.hasPrefix("```") {
                flush()
                code = []
            } else if trimmed.isEmpty {
                flush()
            } else if let m = trimmed.wholeMatch(of: /#{1,6}\s+(.+)/) {
                flush()
                blocks.append(.heading(String(m.1)))
            } else if trimmed.wholeMatch(of: /(?:-{3,}|\*{3,}|_{3,})/) != nil {
                flush()
                blocks.append(.rule)
            } else if let m = trimmed.wholeMatch(of: /[-*+•]\s+(.*)/) {
                flush()
                blocks.append(.item(marker: "•", text: String(m.1), level: level(indent)))
            } else if let m = trimmed.wholeMatch(of: /(\d{1,3})[.)]\s+(.*)/) {
                flush()
                blocks.append(.item(marker: "\(m.1).", text: String(m.2), level: level(indent)))
            } else if let m = trimmed.wholeMatch(of: />\s?(.*)/) {
                flush()
                if case .quote(let previous)? = blocks.last {
                    blocks[blocks.count - 1] = .quote(previous + "\n" + m.1)
                } else {
                    blocks.append(.quote(String(m.1)))
                }
            } else if paragraph.isEmpty, indent > 0, case .item(let marker, let text, let level)? = blocks.last {
                // A wrapped list item.
                blocks[blocks.count - 1] = .item(marker: marker, text: text + " " + trimmed, level: level)
            } else {
                paragraph.append(trimmed)
            }
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    private static func level(_ indent: Int) -> Int { indent < 2 ? 0 : indent < 6 ? 1 : 2 }
}

/// A parsed answer: blocks with their inline styling done once, and where each starts in reading
/// order, so a reveal edge can run across all of them.
@MainActor
struct MarkdownDocument {
    struct Block {
        let kind: MarkdownBlock
        let text: AttributedString
        let offset: Int
    }

    let blocks: [Block]
    let length: Int

    init(_ source: String) {
        var blocks: [Block] = []
        var offset = 0
        for kind in MarkdownBlock.parse(source) {
            let text: AttributedString
            switch kind {
            case .heading(let raw): text = MarkdownText.styled(raw, strong: Typeface.heading)
            case .paragraph(let raw), .quote(let raw): text = MarkdownText.styled(raw, strong: Typeface.readingStrong)
            case .item(_, let raw, _): text = MarkdownText.styled(raw, strong: Typeface.readingStrong)
            case .code(let raw): text = AttributedString(raw)
            case .rule: text = AttributedString(" ")
            }
            blocks.append(Block(kind: kind, text: text, offset: offset))
            // A list marker is one glyph ahead of its item.
            offset += text.characters.count + (kind.isItem ? 1 : 0)
        }
        self.blocks = blocks
        length = offset
    }
}

extension MarkdownBlock {
    fileprivate var isItem: Bool { if case .item = self { true } else { false } }
}

/// Renders an answer. Timecodes become links the chat handles through `openURL`. With a clock, the
/// text writes itself in at the display's rate; without one it is drawn as is.
struct MarkdownText: View {
    let source: String
    var clock: RevealClock?

    var body: some View {
        Group {
            if let clock {
                // Selectable text is drawn by AppKit and skips custom renderers, so selection waits
                // until the answer has written itself in. A half-streamed answer also closes its
                // open bold and code spans instead of showing raw markers.
                let document = MarkdownDocument(Self.closingOpenSpans(source))
                TimelineView(.animation) { context in
                    blocks(document, head: clock.head(at: context.date, length: document.length))
                }
            } else {
                blocks(MarkdownDocument(source), head: nil)
                    .textSelection(.enabled)
            }
        }
        .tint(Palette.accent)
    }

    static func closingOpenSpans(_ text: String) -> String {
        guard let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false).last else { return text }
        var closed = text
        if lastLine.components(separatedBy: "**").count % 2 == 0 { closed += "**" }
        if lastLine.filter({ $0 == "`" }).count % 2 == 1 { closed += "`" }
        return closed
    }

    private func blocks(_ document: MarkdownDocument, head: Double?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(document.blocks.enumerated()), id: \.offset) { _, block in
                view(for: block, head: head.map { $0 - Double(block.offset) })
            }
        }
    }

    @ViewBuilder private func view(for block: MarkdownDocument.Block, head: Double?) -> some View {
        switch block.kind {
        case .heading:
            inline(block.text, heading: true, head: head)
                .padding(.top, Space.xs)
        case .paragraph:
            inline(block.text, head: head)
        case .item(let marker, _, let level):
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text(marker)
                    .font(marker == "•" ? Typeface.reading : Typeface.mono)
                    .foregroundStyle(Palette.inkTertiary)
                    .revealed(head)
                    .frame(minWidth: 12, alignment: .trailing)
                inline(block.text, head: head.map { $0 - 1 })
            }
            .padding(.leading, CGFloat(level) * 18)
        case .quote:
            inline(block.text, color: Palette.inkSecondary, head: head)
                .padding(.leading, Space.m)
                .overlay(alignment: .leading) {
                    Capsule().fill(Palette.hairline).frame(width: 3).opacity(head.map { $0 > 0 ? 1 : 0 } ?? 1)
                }
        case .code:
            ScrollView(.horizontal) {
                Text(block.text)
                    .font(Typeface.mono)
                    .foregroundStyle(Palette.ink)
                    .revealed(head)
                    .padding(Space.m)
            }
            .scrollIndicators(.never)
            .background(
                Palette.hover.opacity(head.map { $0 > 0 ? 1 : 0 } ?? 1),
                in: .rect(cornerRadius: Radius.row, style: .continuous))
        case .rule:
            Rectangle().fill(Palette.hairline).frame(height: 1).padding(.vertical, Space.xs)
                .opacity(head.map { min(max($0 / RevealMotion.window, 0), 1) } ?? 1)
        }
    }

    private func inline(_ text: AttributedString, heading: Bool = false, color: Color = Palette.ink, head: Double?)
        -> some View
    {
        Text(text)
            .font(heading ? Typeface.heading : Typeface.reading)
            .foregroundStyle(color)
            .revealed(head)
            .lineSpacing(Typeface.readingLineSpacing)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Inline Markdown with the type tokens applied: DM Sans has no synthesized bold, so strong runs
    /// get the semibold face explicitly.
    static func styled(_ text: String, strong: Font) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var result = (try? AttributedString(markdown: Citation.link(text), options: options)) ?? AttributedString(text)
        let runs = result.runs.map { ($0.range, $0.link, $0.inlinePresentationIntent) }
        for (range, link, intent) in runs {
            if link?.scheme == Citation.scheme {
                result[range].swiftUI.font = Typeface.cite
                result[range].swiftUI.foregroundColor = Palette.accent
            } else if let intent {
                if intent.contains(.code) {
                    result[range].swiftUI.font = Typeface.mono
                    result[range].swiftUI.backgroundColor = Palette.hover
                } else if intent.contains(.stronglyEmphasized) {
                    result[range].swiftUI.font = strong
                }
            }
        }
        return result
    }
}

extension Text {
    /// Applies the reveal when an edge is given.
    @ViewBuilder fileprivate func revealed(_ head: Double?) -> some View {
        if let head { textRenderer(RevealRenderer(head: head)) } else { self }
    }
}
