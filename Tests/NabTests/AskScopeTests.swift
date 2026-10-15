import Foundation
import Testing

@testable import NabCore

@Suite struct AskScopeTests {
    @Test func latestIsTheNewestEntryWithACapture() {
        let entries = [
            AskScope.Candidate(id: "a", addedAt: Date(timeIntervalSince1970: 300), hasCapture: false),
            AskScope.Candidate(id: "b", addedAt: Date(timeIntervalSince1970: 200), hasCapture: true),
            AskScope.Candidate(id: "c", addedAt: Date(timeIntervalSince1970: 100), hasCapture: true),
        ]
        #expect(AskScope.latestID(in: entries) == "b")
        #expect(AskScope.latestID(in: []) == nil)
        #expect(AskScope.latestID(in: [entries[0]]) == nil)
    }

    @Test func latestIgnoresListOrder() {
        let old = AskScope.Candidate(id: "old", addedAt: Date(timeIntervalSince1970: 1), hasCapture: true)
        let new = AskScope.Candidate(id: "new", addedAt: Date(timeIntervalSince1970: 9), hasCapture: true)
        #expect(AskScope.latestID(in: [old, new]) == "new")
    }

    @Test func startsOnLatestWhenTheSessionIsEmpty() {
        #expect(AskScope.initial(sessionIDs: []) == .latest)
        #expect(AskScope.initial(sessionIDs: ["a"]) == .session)
    }

    @Test func idsFollowTheScope() {
        #expect(AskScope.ids(for: .session, session: ["a", "b"], latest: "c") == ["a", "b"])
        #expect(AskScope.ids(for: .latest, session: ["a", "b"], latest: "c") == ["c"])
        #expect(AskScope.ids(for: .latest, session: ["a"], latest: nil).isEmpty)
    }

    @Test func pickerShowsOnlyWithSeveralVideosAndALatest() {
        #expect(AskScope.offersChoice(session: ["a", "b"], latest: "c"))
        #expect(!AskScope.offersChoice(session: ["a"], latest: "a"))
        #expect(!AskScope.offersChoice(session: [], latest: "c"))
        #expect(!AskScope.offersChoice(session: ["a", "b"], latest: nil))
    }

    @Test func toggleSwitchesWhenThereIsAChoice() {
        #expect(AskScope.session.toggled(offered: true) == .latest)
        #expect(AskScope.latest.toggled(offered: true) == .session)
        #expect(AskScope.session.toggled(offered: false) == .session)
    }

    @Test func summaryHeadingNamesTheVideosOrTheShortTitle() {
        #expect(AskScope.heading(summary: true, question: nil, count: 3, title: nil) == "SUMMARY · 3 VIDEOS")
        #expect(
            AskScope.heading(summary: true, question: nil, count: 1, title: "Learn Python – Full Course for Beginners")
                == "SUMMARY · LEARN PYTHON")
        #expect(AskScope.heading(summary: true, question: nil, count: 1, title: nil) == "SUMMARY · 1 VIDEO")
    }

    @Test func questionHeadingIsTheQuestion() {
        #expect(
            AskScope.heading(summary: false, question: "  Which one first?\n", count: 3, title: nil)
                == "Which one first?")
        #expect(AskScope.heading(summary: false, question: nil, count: 3, title: nil) == "")
    }

    @Test func shortTitleCutsAtASeparatorAndCapsLength() {
        #expect(AskScope.shortTitle("Learn Python – Full Course for Beginners") == "Learn Python")
        #expect(AskScope.shortTitle("Rust: a tour") == "Rust")
        #expect(AskScope.shortTitle("Plain") == "Plain")
        let long = String(repeating: "word ", count: 20)
        #expect(AskScope.shortTitle(long).count <= 32)
        #expect(AskScope.shortTitle(long).hasSuffix("…"))
    }

    @Test func askLinkTextOnlyFillsTheField() {
        #expect(AskScope.draft(fromLinkText: "  what is this?  ") == "what is this?")
        #expect(AskScope.draft(fromLinkText: "   ") == nil)
        #expect(AskScope.draft(fromLinkText: nil) == nil)
        let long = String(repeating: "a", count: AskScope.maxDraftLength + 500)
        #expect(AskScope.draft(fromLinkText: long)?.count == AskScope.maxDraftLength)
    }
}
