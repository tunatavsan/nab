import Testing

@testable import NabCore

@Suite("Who owns the clipboard") struct ClipboardClaimTests {
    /// Nab an item, copy something from the library while it fetches: the item lands and leaves that copy alone.
    @Test func aCopyMadeAfterTheNabIsNeverWrittenOver() {
        var claim = ClipboardClaim()
        let mark = 5
        #expect(claim.mayAutoCopy(mark: mark, current: mark))
        claim.copied(at: 6, automatic: false)
        #expect(!claim.mayAutoCopy(mark: mark, current: 6))
        // The same after an automatic copy that the user's copy then replaced.
        claim.copied(at: 7, automatic: true)
        claim.copied(at: 8, automatic: false)
        #expect(!claim.mayAutoCopy(mark: mark, current: 8))
    }

    /// Items nabbed in a row replace each other's automatic copy, but not a copy the user made in between.
    @Test func itemsNabbedInARowLeaveTheLatestOnTheClipboard() {
        var claim = ClipboardClaim()
        #expect(claim.mayAutoCopy(mark: 5, current: 5))
        claim.copied(at: 6, automatic: true)
        #expect(claim.mayAutoCopy(mark: 5, current: 6))
        claim.copied(at: 7, automatic: true)
        // The user copies (8); a third item nabbed before that lands now and keeps off.
        #expect(!claim.mayAutoCopy(mark: 5, current: 8))
        // An item nabbed after the user's copy may copy itself.
        #expect(claim.mayAutoCopy(mark: 8, current: 8))
    }
}
