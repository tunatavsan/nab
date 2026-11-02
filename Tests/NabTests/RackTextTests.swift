import Foundation
import Testing

@testable import NabCore

@Suite struct RackTextTests {
    @Test func hintsListEveryShortcutByDefault() {
        let hints = RackText.hints(map: ShortcutMap(), unavailable: [])
        #expect(hints.map(\.action) == [.copySession, .summarize, .newSession])
    }

    @Test func hintsOmitRefusedAndClearedShortcuts() {
        var map = ShortcutMap()
        #expect(RackText.hints(map: map, unavailable: [.summarize]).map(\.action) == [.copySession, .newSession])
        map.set(nil, for: .newSession)
        #expect(RackText.hints(map: map, unavailable: [.summarize]).map(\.action) == [.copySession])
        #expect(RackText.hints(map: map, unavailable: [.copySession, .summarize]).isEmpty)
    }

    @Test func headerCountsByKind() {
        #expect(RackText.header(Tally(videos: 1)) == "Session · 1 video")
        #expect(RackText.header(Tally(videos: 2, photos: 1)) == "Session · 2 videos and 1 photo")
        #expect(RackText.header(Tally(photos: 3)) == "Session · 3 photos")
    }

    @Test func tokensRoundToThousands() {
        #expect(RackText.tokens(13_400) == "~13k tokens")
        #expect(RackText.tokens(1_240) == "~1.2k tokens")
        #expect(RackText.tokens(800) == "~800 tokens")
    }

    @Test func detailJoinsLanguageAndTokens() {
        #expect(RackText.detail(language: "Turkish", tokens: 13_000) == "Turkish · ~13k tokens")
        #expect(RackText.detail(language: nil, tokens: 2_000) == "~2.0k tokens")
        #expect(RackText.detail(language: "English", tokens: nil) == "English")
        #expect(RackText.detail(language: nil, tokens: nil) == "")
    }

    @Test func clipboardTitleDependsOnAutoCopy() {
        #expect(RackText.clipboardTitle(copied: true) == "On clipboard · ⌘V into any AI")
        #expect(RackText.clipboardTitle(copied: false) == "Ready")
    }

    @Test func tokenEstimateCountsTranscriptText() {
        #expect(RackText.estimatedTokens(characters: 4_000) == 1_000)
    }

    @Test func earlierTodayCountsOnlyTodaysEntriesOutsideTheSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        func entry(_ id: String, at date: Date, inTray: Bool) -> Entry {
            Entry(id: id, url: URL(string: "https://example.com/\(id)")!, addedAt: date, inTray: inTray)
        }
        let entries = [
            entry("a", at: now, inTray: true),
            entry("b", at: now.addingTimeInterval(-60), inTray: false),
            entry("c", at: now.addingTimeInterval(-86_400 * 2), inTray: false),
        ]
        #expect(RackText.earlierTodayCount(entries, now: now, calendar: calendar) == 1)
        #expect(RackText.earlierTodayEntries(entries, now: now, calendar: calendar).map(\.id) == ["b"])
    }

    @Test func earlierTodayNamesTheKinds() {
        #expect(RackText.earlierToday(Tally(videos: 1)) == "Earlier today · 1 video")
        #expect(RackText.earlierToday(Tally(videos: 2, photos: 2)) == "Earlier today · 2 videos and 2 photos")
    }

    @Test func stackSubtitleFollowsTheClipboard() {
        #expect(RackText.stackSubtitle(copied: true) == "Latest one is on your clipboard")
        #expect(RackText.stackSubtitle(copied: false) == "Copy all puts them on your clipboard")
    }
}
