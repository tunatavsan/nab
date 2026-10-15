import Foundation
import NabCore
import Testing

@Suite("Conversations")
struct ConversationTests {
    @Test func citationsBecomeLinks() {
        let linked = Citation.link(
            "Starts at [1:05], again at [2 12:40] and [1:02:03–1:03:00]; keep [link](https://x.y) and [note].")
        #expect(linked.contains("[1:05](nab-cite://t/0/65)"))
        #expect(linked.contains("[2 · 12:40](nab-cite://t/2/760)"))
        #expect(linked.contains("[1:02:03–1:03:00](nab-cite://t/0/3723)"))
        #expect(linked.contains("[link](https://x.y)"))
        #expect(linked.contains("[note]"))
        #expect(Citation(url: URL(string: "nab-cite://t/2/760")!) == Citation(video: 2, seconds: 760))
        #expect(Citation(url: URL(string: "nab://t/2/760")!) == nil)
    }

    @Test func citationsFromOutsideURLsRejectHostileSeconds() {
        for tail in ["inf", "-inf", "nan", "1e400", "-5", "90000", "1e18"] {
            #expect(Citation(url: URL(string: "nab-cite://t/1/\(tail)")!) == nil, "\(tail)")
        }
        #expect(Citation(url: URL(string: "nab-cite://t/1/86400")!) == Citation(video: 1, seconds: 86_400))
        #expect(Citation(video: nil, seconds: .infinity).url.absoluteString == "nab-cite://t/0/0")
        #expect(Citation(video: nil, seconds: .nan).url.absoluteString == "nab-cite://t/0/0")
    }

    @Test func failedTurnsAreNotSentBack() {
        var chat = Conversation(entryIDs: ["youtube:a"])
        chat.messages = [
            ChatMessage(role: .user, text: "q1"), ChatMessage(role: .assistant, text: "a1"),
            ChatMessage(role: .user, text: "q2"), ChatMessage(role: .assistant, text: "HTTP 500", failed: true),
            ChatMessage(role: .user, text: "q3"),
        ]
        #expect(chat.sendable.map(\.text) == ["q1", "a1", "q3"])
        #expect(Conversation.id(for: ["b", "a"]) == Conversation.id(for: ["a", "b"]))
    }

    @Test func allConversationsListsSavedChatsNewestFirst() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-tests-\(UUID().uuidString)/Library")
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let store = LibraryStore(folder: folder)
        #expect(await store.allConversations().isEmpty)
        var older = Conversation(entryIDs: ["youtube:aaaaaaaaaaa"])
        older.updatedAt = Date(timeIntervalSince1970: 1_000)
        var newer = Conversation(entryIDs: ["youtube:bbbbbbbbbbb", "youtube:ccccccccccc"])
        newer.updatedAt = Date(timeIntervalSince1970: 2_000)
        try await store.save(older)
        try await store.save(newer)
        #expect(await store.allConversations().map(\.id) == [newer.id, older.id])
    }
}
