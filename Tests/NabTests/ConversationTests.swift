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
}
