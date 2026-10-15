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

    // Caption blocks trimmed from real ANDROID player responses (2026-10-15): same track order and
    // audio track ids, other languages dropped, links replaced by placeholders.
    private static func player(captions: String, streaming: String = "null") throws -> Player {
        let json = #"{"captions":{"playerCaptionsTracklistRenderer":\#(captions)},"streamingData":\#(streaming)}"#
        return try JSONDecoder().decode(Player.self, from: Data(json.utf8))
    }

    private static func track(_ code: String, _ kind: String? = nil) -> String {
        let kind = kind.map { #","kind":"\#($0)""# } ?? ""
        return #"{"baseUrl":"https://example.invalid/captions/\#(code)","languageCode":"\#(code)"\#(kind)}"#
    }

    private static func picked(_ player: Player) -> String? {
        YouTubeSource.preferredTrack(in: player)?.baseUrl.split(separator: "/").last.map(String.init)
    }

    @Test func autoDubbedVideoPicksTheOriginalEnglishTrack() throws {  // wm2OVdfr_Oo
        let langs = ["ar", "bn", "nl", "en", "fr", "de"]
        let tracks = langs.map { Self.track($0, "asr") }.joined(separator: ",")
        let audio = ["ru.10", "de-DE.10", "ta.10", "fr-FR.10", "en-US.4", "iw.10"]
            .map { #"{"audioTrackId":"\#($0)"}"# }.joined(separator: ",")
        let player = try Self.player(
            captions: #"{"captionTracks":[\#(tracks)],"audioTracks":[\#(audio)],"defaultAudioTrackIndex":4}"#)
        #expect(Self.picked(player) == "en")
        #expect(player.captions?.playerCaptionsTracklistRenderer?.captionTracks?.first?.languageCode == "ar")
    }

    @Test func manualTracksPreferTheOriginalLanguageOverTheFirst() throws {  // rfscVS0vtbw
        let tracks = ["ar", "bg", "zh-CN", "en", "iw", "tr"].map { Self.track($0) }.joined(separator: ",")
        let audio = [#"{"audioTrackId":"en.4","defaultCaptionTrackIndex":3}"#, #"{"audioTrackId":"es.3"}"#]
            .joined(separator: ",")
        let player = try Self.player(
            captions: #"{"captionTracks":[\#(tracks)],"audioTracks":[\#(audio)],"defaultAudioTrackIndex":0}"#)
        #expect(Self.picked(player) == "en")
    }

    @Test func originalIsFoundByItsSuffixWhenNoDefaultIndexIsGiven() throws {  // QGWKCaglSBI shape
        let tracks = ["nl", "en", "fr", "de"].map { Self.track($0, "asr") }.joined(separator: ",")
        let audio = ["ta.10", "de-DE.10", "en-US.4", "fr-FR.10"].map { #"{"audioTrackId":"\#($0)"}"# }
            .joined(separator: ",")
        let player = try Self.player(captions: #"{"captionTracks":[\#(tracks)],"audioTracks":[\#(audio)]}"#)
        #expect(Self.picked(player) == "en")
    }

    @Test func originalBeatsADubbedDefaultAudioTrack() throws {  // Turkish video, English dub played by default
        let tracks = ["en", "tr"].map { Self.track($0, "asr") }.joined(separator: ",")
        let audio = ["en.10", "tr.4"].map { #"{"audioTrackId":"\#($0)"}"# }.joined(separator: ",")
        let player = try Self.player(
            captions: #"{"captionTracks":[\#(tracks)],"audioTracks":[\#(audio)],"defaultAudioTrackIndex":0}"#)
        #expect(Self.picked(player) == "tr")
    }

    @Test func turkishOriginalWinsOverItsEnglishDub() throws {  // qZ1Z3g0HkHw: hl=en marks the dub as default
        let tracks = ["en", "tr"].map { Self.track($0, "asr") }.joined(separator: ",")
        let audio = ["tr.4", "en-US.3"].map { #"{"audioTrackId":"\#($0)"}"# }.joined(separator: ",")
        let streaming = #"{"adaptiveFormats":[{"audioTrack":{"id":"en-US.3","audioIsDefault":true}}]}"#
        let player = try Self.player(
            captions: #"{"captionTracks":[\#(tracks)],"audioTracks":[\#(audio)],"defaultAudioTrackIndex":0}"#,
            streaming: streaming)
        #expect(Self.picked(player) == "tr")
    }

    @Test func originalFallsBackToTheDefaultAudioFormat() throws {
        let tracks = ["ar", "en"].map { Self.track($0, "asr") }.joined(separator: ",")
        let streaming =
            #"{"adaptiveFormats":[{"itag":137},{"audioTrack":{"id":"es.10","audioIsDefault":false}},{"audioTrack":{"id":"en-US.4","audioIsDefault":true}}]}"#
        let player = try Self.player(
            captions: #"{"captionTracks":[\#(tracks)],"audioTracks":[{}],"defaultAudioTrackIndex":0}"#,
            streaming: streaming)
        #expect(Self.picked(player) == "en")
    }

    @Test func humanTrackBeatsAutoGeneratedInTheOriginalLanguage() throws {
        let tracks = [Self.track("ar", "asr"), Self.track("en", "asr"), Self.track("en-GB")].joined(separator: ",")
        let player = try Self.player(
            captions:
                #"{"captionTracks":[\#(tracks)],"audioTracks":[{"audioTrackId":"en-US.4"}],"defaultAudioTrackIndex":0}"#
        )
        #expect(Self.picked(player) == "en-GB")
    }

    @Test func defaultCaptionIndexIsUsedWhenNoTrackMatchesTheOriginal() throws {
        let tracks = ["ar", "de", "fr"].map { Self.track($0) }.joined(separator: ",")
        let player = try Self.player(
            captions:
                #"{"captionTracks":[\#(tracks)],"audioTracks":[{"audioTrackId":"ja.4","defaultCaptionTrackIndex":2}],"defaultAudioTrackIndex":0}"#
        )
        #expect(Self.picked(player) == "fr")
    }

    @Test func singleTrackWithoutAudioIdsKeepsWorking() throws {  // -9SvqjJszrY
        let player = try Self.player(
            captions:
                #"{"captionTracks":[\#(Self.track("tr", "asr"))],"audioTracks":[{"captionTrackIndices":[0]}],"defaultAudioTrackIndex":0}"#
        )
        #expect(Self.picked(player) == "tr")
    }

    @Test func missingAudioBlocksKeepTheExistingRule() throws {
        let tracks = [Self.track("ar"), Self.track("en", "asr"), Self.track("en-GB")].joined(separator: ",")
        #expect(Self.picked(try Self.player(captions: #"{"captionTracks":[\#(tracks)]}"#)) == "en-GB")
        let bare = try JSONDecoder().decode(Player.self, from: Data("{}".utf8))
        #expect(YouTubeSource.preferredTrack(in: bare) == nil)
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
