import Foundation
import Testing

@testable import NabCore

@Suite struct RecordActionsTests {
    private func pin(saved: [String?]) -> Capture {
        Capture(
            source: SourceKind(rawValue: "pinterest"), sourceID: "1", url: URL(string: "https://example.com/pin/1")!,
            title: "Pin",
            media: saved.map {
                Media(kind: .image, url: URL(string: "https://example.com/a.jpg")!, savedPath: $0)
            })
    }

    @Test func openLabelNamesTheSource() {
        #expect(RecordActions.openLabel(sourceName: "Pinterest") == "Open on Pinterest")
    }

    @Test func finderSelectsOnlyFilesThatAreStillThere() {
        let capture = pin(saved: ["/m/a.jpg", "/m/gone.jpg", nil])
        let files = RecordActions.finderFiles(capture, size: { $0 == "/m/gone.jpg" ? nil : 1 })
        #expect(files.map(\.path) == ["/m/a.jpg"])
        // A file the user edited since is still theirs and is selected; an emptied one is not, the same as Copy.
        var edited = pin(saved: ["/m/a.jpg"])
        edited.media[0].byteCount = 10
        #expect(RecordActions.finderFiles(edited, size: { _ in 9 }).map(\.path) == ["/m/a.jpg"])
        #expect(RecordActions.finderFiles(edited, size: { _ in 0 }).isEmpty)
    }

    @Test func aRecordReadAsTextHasNothingForFinder() {
        let text = Capture(
            source: .youtube, sourceID: "dQw4w9WgXcQ", url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, title: "T")
        #expect(RecordActions.finderFiles(text, size: { _ in 1 }).isEmpty)
    }

    @Test func twoAbsencesAreNotAMatchForTheEmbeddedPlayer() {
        #expect(!RecordActions.isEmbedded(playing: nil, entryID: "pinterest:1"))
        #expect(!RecordActions.isEmbedded(playing: nil, entryID: "youtube:dQw4w9WgXcQ"))
        #expect(!RecordActions.isEmbedded(playing: "dQw4w9WgXcQ", entryID: "pinterest:1"))
        #expect(!RecordActions.isEmbedded(playing: "aaaaaaaaaaa", entryID: "youtube:dQw4w9WgXcQ"))
        #expect(RecordActions.isEmbedded(playing: "dQw4w9WgXcQ", entryID: "youtube:dQw4w9WgXcQ"))
    }
}
