import Foundation
import Testing

@testable import NabCore

@Suite("Transcript search")
struct TranscriptSearchTests {
    private let paragraphs = [
        Paragraph(start: 0, text: "Welcome. Today we install Python and set the PATH.", chapter: "Intro"),
        Paragraph(start: 60, text: "Nothing to find in this one.", chapter: nil),
        Paragraph(start: 120, text: "Check the path again: path, PATH and Path.", chapter: "Setup"),
    ]
    private let chapters = [Chapter(start: 0, title: "Intro"), Chapter(start: 120, title: "Setup")]

    private func search(_ query: String) -> TranscriptSearch {
        TranscriptSearch(paragraphs: paragraphs, chapters: chapters, query: query)
    }

    @Test func findsEveryMatchIgnoringCase() {
        let result = search("path")
        #expect(result.matches.count == 5)
        #expect(result.matches.map(\.paragraph) == [0, 2, 2, 2, 2])
        #expect(result.matches.map(\.time) == [0, 120, 120, 120, 120])
    }

    @Test func rangesPointAtTheMatchedCharacters() throws {
        let first = try #require(search("python").matches.first)
        let text = paragraphs[0].text
        let start = text.index(text.startIndex, offsetBy: first.offset)
        let end = text.index(start, offsetBy: first.length)
        #expect(text[start..<end] == "Python")
    }

    @Test func ignoresDiacriticsAndOuterWhitespace() {
        let result = TranscriptSearch(
            paragraphs: [Paragraph(start: 0, text: "Çay ve şeker", chapter: nil)], chapters: [], query: "  cay ")
        #expect(result.matches.count == 1)
        #expect(result.matches[0].length == 3)
    }

    @Test func emptyQueryFindsNothing() {
        #expect(search("").matches.isEmpty)
        #expect(search("   ").matches.isEmpty)
        #expect(!search(" ").isActive)
    }

    @Test func countsMatchesPerChapter() {
        let result = search("path")
        #expect(result.count(inChapter: 0) == 1)
        #expect(result.count(inChapter: 1) == 4)
        #expect(result.count(inChapter: 5) == 0)
    }

    @Test func matchesBeforeTheFirstChapterBelongToNone() {
        let result = TranscriptSearch(
            paragraphs: [Paragraph(start: 3, text: "alpha", chapter: nil)],
            chapters: [Chapter(start: 30, title: "Later")], query: "alpha")
        #expect(result.matches[0].chapter == nil)
    }

    @Test func nextAndPreviousWrapAround() {
        let result = search("path")
        #expect(result.index(after: nil) == 0)
        #expect(result.index(after: 0) == 1)
        #expect(result.index(after: 4) == 0)
        #expect(result.index(before: nil) == 4)
        #expect(result.index(before: 0) == 4)
        #expect(result.index(before: 2) == 1)
        #expect(search("zzz").index(after: nil) == nil)
    }

    @Test func groupsMatchesByParagraph() {
        let result = search("path")
        #expect(result.matches(inParagraph: 0).map(\.index) == [0])
        #expect(result.matches(inParagraph: 2).map(\.index) == [1, 2, 3, 4])
        #expect(result.matches(inParagraph: 1).isEmpty)
    }

    @Test func findsTheChapterAtATime() {
        #expect(TranscriptSearch.chapterIndex(at: 0, in: chapters) == 0)
        #expect(TranscriptSearch.chapterIndex(at: 119.6, in: chapters) == 1)
        #expect(TranscriptSearch.chapterIndex(at: 500, in: chapters) == 1)
        #expect(TranscriptSearch.chapterIndex(at: 3, in: [Chapter(start: 30, title: "x")]) == nil)
        #expect(TranscriptSearch.chapterIndex(at: 3, in: []) == nil)
    }
}
