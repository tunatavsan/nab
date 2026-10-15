import NabCore
import SwiftUI

/// Paragraphs of a transcript are grouped once per capture; a four-hour video has thousands of segments.
@MainActor
enum TranscriptCache {
    private static var store: [String: (key: Int, paragraphs: [Paragraph])] = [:]

    /// `window` is the passage length in seconds: 45 for reading, shorter for the drawer.
    static func paragraphs(of capture: Capture, id: String, window: TimeInterval = 45) -> [Paragraph] {
        guard let transcript = capture.transcript else { return [] }
        let key = transcript.segments.count &* 31 &+ capture.chapters.count
        let slot = "\(id)@\(Int(window))"
        if let hit = store[slot], hit.key == key { return hit.paragraphs }
        let paragraphs = transcript.paragraphs(chapters: capture.chapters, window: window)
        store[slot] = (key, paragraphs)
        return paragraphs
    }
}

enum TranscriptText {
    /// A paragraph with its find hits marked: washed, and the current one filled.
    @MainActor
    static func marked(
        _ text: String, matches: [(index: Int, match: TranscriptMatch)], current: Int?
    ) -> AttributedString {
        var result = AttributedString(text)
        let count = result.characters.count
        for (index, match) in matches where match.offset + match.length <= count {
            let start = result.characters.index(result.startIndex, offsetBy: match.offset)
            let end = result.characters.index(start, offsetBy: match.length)
            let on = index == current
            result[start..<end].backgroundColor = on ? Palette.accent : Palette.accentWash
            result[start..<end].foregroundColor = on ? Palette.onAccent : Palette.accentInk
        }
        return result
    }

    /// The whole transcript as plain text, one timecoded passage per paragraph.
    static func plain(_ paragraphs: [Paragraph]) -> String {
        paragraphs.map { "\(Timecode.string($0.start))  \($0.text)" }.joined(separator: "\n\n")
    }
}

/// A small icon button for field adornments: 18 pt, quiet until hovered.
struct FieldIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.iconSmall)
                .foregroundStyle(hovering ? Palette.ink : Palette.inkSecondary)
                .frame(width: 20, height: 20)
                .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: 5, style: .continuous))
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .help(help)
        .accessibilityLabel(help)
    }
}
