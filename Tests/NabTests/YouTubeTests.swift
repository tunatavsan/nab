import Foundation
import NabCore
import Testing

@testable import NabYouTube

@Suite("YouTube")
struct YouTubeTests {
    @Test func videoIDsFromEveryLinkShape() {
        let cases = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s": "dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ?si=abc": "dQw4w9WgXcQ",
            "https://m.youtube.com/shorts/dQw4w9WgXcQ": "dQw4w9WgXcQ",
            "https://www.youtube.com/live/dQw4w9WgXcQ": "dQw4w9WgXcQ",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ": "dQw4w9WgXcQ",
        ]
        for (link, id) in cases { #expect(YouTubeURL.videoID(in: URL(string: link)!) == id, "\(link)") }
        #expect(YouTubeURL.videoID(in: URL(string: "https://www.youtube.com/@channel")!) == nil)
        #expect(YouTubeURL.videoID(in: URL(string: "https://example.com/watch?v=dQw4w9WgXcQ")!) == nil)
    }

    @Test func chaptersNeedAStartAtZero() {
        let description = """
            Links below.
            0:00 Intro
            1:30 - The setup
            (12:05) Results
            1:02:03 Q&A
            """
        let chapters = YouTubeChapters.parse(description)
        #expect(chapters.map(\.start) == [0, 90, 725, 3723])
        #expect(chapters.map(\.title) == ["Intro", "The setup", "Results", "Q&A"])
        #expect(YouTubeChapters.parse("2:00 Late start\n3:00 More").isEmpty)
    }

    @Test func timedTextDropsEmptyEvents() throws {
        let json =
            #"{"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[{"utf8":"Hello"},{"utf8":" world"}]},{"tStartMs":900,"segs":[{"utf8":"\n"}]},{"tStartMs":2000,"dDurationMs":500}]}"#
        let segments = try TimedText.segments(from: Data(json.utf8))
        #expect(segments == [Segment(start: 0, duration: 1, text: "Hello world")])
    }

    @Test func spokenLanguageTrackWinsByLanguageNotPrefix() throws {
        func tracks(_ json: String) throws -> [Player.Track] {
            try JSONDecoder().decode([Player.Track].self, from: Data(json.utf8))
        }
        let english = try tracks(
            #"[{"baseUrl":"a","languageCode":"en","kind":"asr"},{"baseUrl":"b","languageCode":"de"},{"baseUrl":"c","languageCode":"en-GB"}]"#
        )
        #expect(YouTubeSource.preferredTrack(english)?.baseUrl == "c")
        // Filipino ("fil") and Finnish ("fi") share a prefix but not a language.
        let filipino = try tracks(
            #"[{"baseUrl":"a","languageCode":"fil","kind":"asr"},{"baseUrl":"b","languageCode":"fi"}]"#)
        #expect(YouTubeSource.preferredTrack(filipino)?.baseUrl == "a")
        #expect(YouTubeSource.preferredTrack(try tracks(#"[{"baseUrl":"b","languageCode":"fi"}]"#))?.baseUrl == "b")
    }

    @Test func coversAndMomentLinksComeFromTheProvider() {
        let source = YouTubeSource()
        #expect(
            source.covers(forID: "abc").map(\.lastPathComponent) == [
                "maxresdefault.jpg", "hqdefault.jpg", "mqdefault.jpg",
            ])
        let capture = Capture(source: .youtube, sourceID: "abc", url: URL(string: "https://youtu.be/abc")!, title: "T")
        #expect(source.link(to: capture, at: 65.9).absoluteString == "https://www.youtube.com/watch?v=abc&t=65s")
    }
}
