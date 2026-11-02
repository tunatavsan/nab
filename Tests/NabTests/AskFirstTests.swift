import Foundation
import Testing

@testable import NabCore

@Suite struct AskFirstTests {
    @Test func theFrontTabWinsOverASessionOfOthers() {
        #expect(AskScope.initial(sessionIDs: ["a", "b"], focus: "f") == .latest)
        #expect(AskScope.initial(sessionIDs: ["a", "b"]) == .session)
        // The record still being read stands in for "latest", so the picker offers the session beside it.
        #expect(AskScope.ids(for: .latest, session: ["a", "b"], latest: "f") == ["f"])
        #expect(AskScope.offersChoice(session: ["a", "b"], latest: "f"))
    }

    @Test func summarizeLeadsTheHintsOnlyOnAnEmptyChat() {
        #expect(
            AskScope.hints(chatIsEmpty: true).first
                == .init(key: "⌘↩", label: "Summarize", spoken: "Command Return summarizes."))
        #expect(!AskScope.hints(chatIsEmpty: false).contains { $0.key == "⌘↩" })
        #expect(AskScope.hints(chatIsEmpty: true).count == AskScope.hints(chatIsEmpty: false).count + 1)
    }

    @Test func switchHintDoesNotCallEverythingAVideo() {
        let labels = AskScope.hints(chatIsEmpty: true).map { $0.label + $0.spoken }
        #expect(!labels.contains { $0.lowercased().contains("video") })
    }

    @Test func summaryStartsOnlyOnAnEmptyIdleChat() {
        #expect(AskScope.canSummarize(chatIsEmpty: true, busy: false, waiting: false))
        #expect(!AskScope.canSummarize(chatIsEmpty: false, busy: false, waiting: false))
        #expect(!AskScope.canSummarize(chatIsEmpty: true, busy: true, waiting: false))
        #expect(!AskScope.canSummarize(chatIsEmpty: true, busy: false, waiting: true))
    }

    @Test func aHeldQuestionNamesWhatItWaitsFor() {
        #expect(AskScope.waitingLabel == "Waiting for the details…")
    }

    @Test func onlyASendInTheSessionScopeUsesItUp() {
        #expect(AskScope.sendUsesSession(scope: .session, pinned: false, count: 2))
        #expect(!AskScope.sendUsesSession(scope: .latest, pinned: false, count: 1))
        #expect(!AskScope.sendUsesSession(scope: .session, pinned: true, count: 1))
        #expect(!AskScope.sendUsesSession(scope: .session, pinned: false, count: 0))
    }

    @Test func aHeldQuestionGoesWhenARecordIsReadyAndFailsWithTheReasonOtherwise() {
        #expect(AskScope.resolveHeld(readyCount: 1, failure: "x") == .send)
        #expect(AskScope.resolveHeld(readyCount: 0, failure: "No captions.") == .fail("No captions."))
        #expect(
            AskScope.resolveHeld(readyCount: 0, failure: nil)
                == .fail("The details did not arrive. Try again in a moment."))
        #expect(
            AskScope.resolveHeld(readyCount: 0, failure: "")
                == .fail("The details did not arrive. Try again in a moment."))
    }

    @Test func aClickRightAfterATimecodeDoesNotCloseTheWindow() {
        #expect(AskScope.closesOnOutsideClick(sinceCitation: nil))
        #expect(!AskScope.closesOnOutsideClick(sinceCitation: 1))
        #expect(AskScope.closesOnOutsideClick(sinceCitation: AskScope.citationGrace + 1))
    }

    @Test func aRecordThatCouldNotBeReadShowsWhyInsteadOfWaiting() {
        #expect(AskScope.sendPlan(readyCount: 0, reading: false, failure: "No captions.") == .fail("No captions."))
        #expect(AskScope.sendPlan(readyCount: 0, reading: false, failure: nil) == .refuse)
        #expect(AskScope.sendPlan(readyCount: 1, reading: true, failure: nil) == .hold)
        #expect(AskScope.sendPlan(readyCount: 1, reading: false, failure: "x") == .send)
    }

    @Test func anEmptyChatShowsSummarizeWhateverHeldTheAutoSend() {
        #expect(AskScope.emptyState(choosing: false, providerProblem: false, waiting: false, busy: false) == .summarize)
        #expect(AskScope.emptyState(choosing: false, providerProblem: false, waiting: true, busy: false) == .waiting)
        #expect(AskScope.emptyState(choosing: false, providerProblem: false, waiting: false, busy: true) == .reading)
        #expect(AskScope.emptyState(choosing: true, providerProblem: false, waiting: true, busy: false) == .chooser)
        #expect(AskScope.emptyState(choosing: false, providerProblem: true, waiting: false, busy: false) == .chooser)
    }

    @Test func handedIdsFindTheLiveSessionEvenWithRecordsStillBeingRead() {
        // The session holds the front tab's record (still fetching) and one ready record.
        let session = ["front", "a"]
        #expect(
            AskScope.placement(handed: ["front", "a"], session: session, readySession: ["a"], latest: "front")
                == .session)
        #expect(AskScope.placement(handed: ["a"], session: session, readySession: ["a"], latest: "front") == .session)
        #expect(
            AskScope.placement(handed: ["front"], session: session, readySession: ["a"], latest: "front") == .latest)
        #expect(AskScope.placement(handed: ["z"], session: session, readySession: ["a"], latest: "front") == .pinned)
        #expect(AskScope.offersChoice(session: session, latest: "front"))
    }
}

@Suite struct AskStableChatTests {
    @Test func aChatSentOnStaysOnItsRecordsWhenOneFails() {
        // Sent on [f, a]; then f fails and leaves the live session.
        let ids = AskScope.windowIDs(locked: ["f", "a"], pinned: nil, scope: .session, session: ["a"], latest: "a")
        #expect(ids == ["f", "a"])
    }

    @Test func aNewRecordDoesNotMoveTheChatAfterASend() {
        let locked = AskScope.windowIDs(
            locked: ["a"], pinned: nil, scope: .session, session: ["n", "a"], latest: "n")
        #expect(locked == ["a"])
        // Before anything is sent the scope is live.
        let live = AskScope.windowIDs(locked: nil, pinned: nil, scope: .session, session: ["n", "a"], latest: "n")
        #expect(live == ["n", "a"])
    }

    @Test func aRecordWithACaptureStaysEvenIfItsLaterStepFailed() {
        let members = AskScope.sessionMembers([
            (id: "saved", hasCapture: true, reading: false),
            (id: "reading", hasCapture: false, reading: true),
            (id: "failed", hasCapture: false, reading: false),
        ])
        #expect(members == ["saved", "reading"])
    }

    @Test func aHeldQuestionGoesAfterTheLimitWithWhatIsReady() {
        let start = Date(timeIntervalSince1970: 1000)
        #expect(!AskScope.holdExpired(since: start, now: start.addingTimeInterval(119)))
        #expect(AskScope.holdExpired(since: start, now: start.addingTimeInterval(120)))
        #expect(AskScope.sendPlan(readyCount: 1, reading: true, failure: nil) == .hold)
        #expect(AskScope.sendPlan(readyCount: 1, reading: true, failure: nil, timedOut: true) == .send)
        #expect(AskScope.missingNote(titles: ["Lesson"]).contains("“Lesson” did not arrive"))
    }
}
