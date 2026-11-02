import Foundation

@testable import NabCore

/// YouTube captures with every field the context pack prints, frozen before photos and clips joined the pack, so
/// the pack for videos stays byte for byte what it was.
enum PackGolden {
    static let day = Date(timeIntervalSince1970: 1_790_000_000)

    static var captures: [Capture] {
        let segments = (0..<12).map {
            Segment(start: Double($0) * 9, duration: 9, text: $0 % 4 == 3 ? "Line \($0) ends." : "line \($0)")
        }
        var full = Capture(
            source: .youtube, sourceID: "dQw4w9WgXcQ", url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
            title: "A <source> talk", author: "Someone", authorURL: URL(string: "https://www.youtube.com/@someone"),
            duration: 3725, viewCount: 999, summary: "Description line one.\nLine two.",
            keywords: ["talk", "demo"],
            thumbnailURL: URL(string: "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg"),
            chapters: [Chapter(start: 0, title: "Intro"), Chapter(start: 54, title: "Middle")],
            transcript: Transcript(languageCode: "en", languageName: "English", isGenerated: true, segments: segments))
        full.aiSummary = "Short answer [0:09]."
        full.aiModel = "claude-sonnet"
        let bare = Capture(
            source: .youtube, sourceID: "rfscVS0vtbw", url: URL(string: "https://youtu.be/rfscVS0vtbw")!,
            title: "No captions here")
        return [full, bare]
    }

    /// What `ContextPack.render(captures, capturedAt: day)` printed at e50eb75.
    static let pack = """
        <nab_context sources="2" packed="2026-09-21">
        Index:
        1. A &lt;source> talk — Someone (1:02:05)
        2. No captions here

        <source type="youtube" id="dQw4w9WgXcQ" url="https://www.youtube.com/watch?v=dQw4w9WgXcQ">
        # A &lt;source> talk

        ![Cover](https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg)

        - Channel: Someone
        - Duration: 1:02:05
        - Views: 999
        - Transcript: English, auto-generated

        ## Summary (by claude-sonnet)
        Short answer [0:09].

        ## Chapters
        [0:00] Intro
        [0:54] Middle

        ## Description
        Description line one.
        Line two.

        ## Transcript

        ### Intro
        [0:00] line 0 line 1 line 2 Line 3 ends. line 4 line 5

        ### Middle
        [0:54] line 6 Line 7 ends. line 8 line 9 line 10 Line 11 ends.
        </source>

        <source type="youtube" id="rfscVS0vtbw" url="https://youtu.be/rfscVS0vtbw">
        # No captions here

        - Transcript: none available
        </source>
        </nab_context>

        """
}
