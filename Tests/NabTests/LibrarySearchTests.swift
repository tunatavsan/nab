import Foundation
import Testing

@testable import NabCore

@Suite("Library search")
struct LibrarySearchTests {
    private func video(_ id: String, _ title: String, author: String? = nil, lines: [(Double, String)] = []) -> Entry {
        var e = Entry(id: "youtube:\(id)", url: URL(string: "https://youtu.be/\(id)")!)
        e.capture = Capture(
            source: .youtube, sourceID: id, url: e.url, title: title, author: author,
            transcript: Transcript(
                languageCode: "en", languageName: nil, isGenerated: false,
                segments: lines.map { Segment(start: $0.0, duration: 3, text: $0.1) }))
        return e
    }

    @Test func highlightMarksEveryMatchIgnoringCaseAndDiacritics() {
        let parts = LibrarySearch.highlight("Python ve PYTHON, İstanbul", terms: ["python", "istanbul"])
        #expect(parts.filter(\.isMatch).map(\.text) == ["Python", "PYTHON", "İstanbul"])
        #expect(parts.map(\.text).joined() == "Python ve PYTHON, İstanbul")
    }

    @Test func highlightMergesOverlaps() {
        let parts = LibrarySearch.highlight("pythonic", terms: ["pyth", "thon"])
        #expect(parts == [HighlightPart(text: "python", isMatch: true), HighlightPart(text: "ic", isMatch: false)])
    }

    @Test func everyTermMustMatch() {
        #expect(LibrarySearch.matches("Learn Python fast", terms: ["python", "learn"]))
        #expect(!LibrarySearch.matches("Learn Python fast", terms: ["python", "swift"]))
        #expect(!LibrarySearch.matches("anything", terms: []))
    }

    @Test func titleMatchesRankAboveAuthorMatches() {
        let entries = [
            video("a", "Cooking", author: "Python Guy"), video("b", "Learn Python"), video("c", "Other"),
        ]
        let result = LibrarySearch.search("python", entries: entries, chats: [])
        #expect(result.videos.map(\.entryID) == ["youtube:b", "youtube:a"])
        #expect(result.videos[0].title.contains { $0.isMatch })
    }

    @Test func videoLimit() {
        let entries = (0..<20).map { video("v\($0)", "Python \($0)") }
        #expect(LibrarySearch.search("python", entries: entries, chats: []).videos.count == LibrarySearch.maxVideos)
    }

    @Test func transcriptHitsLimitedPerVideoAndInAll() {
        let lines = (0..<10).map { (Double($0) * 60, "python line \($0)") }
        let entries = (0..<6).map { video("v\($0)", "Video \($0)", lines: lines) }
        let result = LibrarySearch.search("python", entries: entries, chats: [])
        #expect(result.transcripts.count == LibrarySearch.maxTranscriptHits)
        #expect(result.transcriptTotal == 60)
        for entry in entries {
            #expect(result.transcripts.filter { $0.entryID == entry.id }.count <= LibrarySearch.maxPerVideo)
        }
        #expect(result.transcripts[0].seconds == 0)
    }

    @Test func closeLinesCountOnce() {
        let e = video("a", "Video", lines: [(10, "python one"), (14, "python two"), (60, "python three")])
        let result = LibrarySearch.search("python", entries: [e], chats: [])
        #expect(result.transcripts.map(\.seconds) == [10, 60])
    }

    @Test func chatsMatchTheirTitle() {
        var c = Conversation(entryIDs: ["youtube:a"])
        c.messages = [
            ChatMessage(role: .user, text: "Python mu Swift mi?"), ChatMessage(role: .assistant, text: "Swift."),
        ]
        var other = Conversation(entryIDs: ["youtube:b"])
        other.messages = [ChatMessage(role: .user, text: "Nothing"), ChatMessage(role: .assistant, text: "x")]
        let result = LibrarySearch.search("python", entries: [video("a", "A"), video("b", "B")], chats: [c, other])
        #expect(result.chats.map(\.id) == ["youtube:a"])
    }

    @Test func emptyQueryListsRecents() {
        let entries = (0..<10).map { video("v\($0)", "T\($0)") }
        let result = LibrarySearch.search("  ", entries: entries, chats: [])
        #expect(result.videos.count == LibrarySearch.maxVideos)
        #expect(result.transcripts.isEmpty)
        #expect(LibrarySearch.search("zzz", entries: entries, chats: []).isEmpty)
    }
}
