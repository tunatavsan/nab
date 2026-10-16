import Foundation
import Testing

@testable import NabCore

@Suite("Bug-hunt regressions")
struct RegressionTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "nab-tests-\(UUID().uuidString)/Library")
    }

    @Test func staleSearchHitNeverPointsOutsideNewParagraphs() {
        let old = (0..<3).map { Paragraph(start: Double($0) * 45, text: "alpha", chapter: nil) }
        let search = TranscriptSearch(paragraphs: old, query: "alpha")
        #expect(search.paragraphCount == 3)
        #expect(search.match(at: 2, paragraphCount: 3)?.paragraph == 2)
        // Segment count stayed the same but the paragraphs regrouped into fewer ones.
        #expect(search.match(at: 2, paragraphCount: 2) == nil)
        #expect(search.match(at: 9, paragraphCount: 3) == nil)
    }

    @Test func searchRunsOffTheCallerAndMatchesTheSyncResult() async {
        let paragraphs = [Paragraph(start: 0, text: "Çay and cay", chapter: nil)]
        let found = await TranscriptSearch.run(paragraphs: paragraphs, chapters: [], query: "cay")
        #expect(found.matches == TranscriptSearch(paragraphs: paragraphs, query: "cay").matches)
        #expect(found.matches.count == 2)
    }

    @Test func removingAVideoDropsOnlyChatsLeftWithNoVideo() {
        let single = Conversation(entryIDs: ["youtube:a"])
        let pack = Conversation(entryIDs: ["youtube:a", "youtube:b"])
        let orphanPack = Conversation(entryIDs: ["youtube:a", "youtube:d"])
        let other = Conversation(entryIDs: ["youtube:c"])
        let gone = Conversation.ids(
            about: ["youtube:a", "youtube:d"], keeping: ["youtube:b", "youtube:c"],
            in: [single, pack, orphanPack, other])
        #expect(Set(gone) == [single.id, orphanPack.id])
    }

    @Test func corruptEntryIsSetAsideNotOverwritten() async throws {
        let dir = folder()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LibraryStore(folder: dir)
        let id = "youtube:abc"
        try await store.save(Entry(id: id, url: URL(string: "https://youtu.be/abc")!))
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        try Data("{ not json".utf8).write(to: file)

        #expect(await store.loadAll().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let aside = file.appendingPathExtension("corrupt")
        #expect(try String(contentsOf: aside, encoding: .utf8) == "{ not json")

        // Saving the same id again keeps the broken copy, and a second pass leaves everything alone.
        try await store.save(Entry(id: id, url: URL(string: "https://youtu.be/abc")!))
        #expect(await store.loadAll().count == 1)
        #expect(FileManager.default.fileExists(atPath: aside.path))
    }

    @Test func corruptChatIsSetAside() async throws {
        let dir = folder()
        let store = LibraryStore(folder: dir)
        var chat = Conversation(entryIDs: ["youtube:a"])
        chat.messages = [ChatMessage(role: .user, text: "hi")]
        try await store.save(chat)
        let chats = dir.deletingLastPathComponent().appending(path: "Chats")
        let file = try #require(
            FileManager.default.contentsOfDirectory(at: chats, includingPropertiesForKeys: nil).first)
        try Data("oops".utf8).write(to: file)
        #expect(await store.allConversations().isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("corrupt").path))
    }
}
