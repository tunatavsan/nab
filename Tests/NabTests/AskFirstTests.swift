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
}
