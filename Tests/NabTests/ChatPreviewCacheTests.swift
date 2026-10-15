import Foundation
import NabCore
import Testing

@Suite("Chat preview cache")
struct ChatPreviewCacheTests {
    private func chat(_ id: String, answer: String = "Hello [1:05]") -> Conversation {
        var chat = Conversation(entryIDs: [id])
        chat.messages = [ChatMessage(role: .user, text: "What is it?"), ChatMessage(role: .assistant, text: answer)]
        return chat
    }

    @Test func buildsOncePerUnchangedChat() {
        let cache = ChatPreviewCache()
        let a = chat("a")
        let first = cache.preview(for: a, titleOf: { _ in "A" })
        let second = cache.preview(for: a, titleOf: { _ in "A" })
        #expect(first == second)
        #expect(cache.builds == 1)
        _ = cache.previews(for: [a, chat("b")], titleOf: { _ in "A" })
        #expect(cache.builds == 2)
    }

    @Test func rebuildsWhenTheChatChanges() {
        let cache = ChatPreviewCache()
        var a = chat("a")
        _ = cache.preview(for: a, titleOf: { _ in nil })
        a.messages.append(ChatMessage(role: .user, text: "And then?"))
        _ = cache.preview(for: a, titleOf: { _ in nil })
        #expect(cache.builds == 2)
        a.updatedAt = a.updatedAt.addingTimeInterval(5)
        let refreshed = cache.preview(for: a, titleOf: { _ in nil })
        #expect(cache.builds == 3)
        #expect(refreshed.updatedAt == a.updatedAt)
    }

    @Test func rebuildsWhenTheVideoTitleBehindASummaryChanges() {
        let cache = ChatPreviewCache()
        var a = Conversation(entryIDs: ["a"])
        a.messages = [
            ChatMessage(role: .user, text: "Summarize", isSummaryRequest: true),
            ChatMessage(role: .assistant, text: "x"),
        ]
        #expect(cache.preview(for: a, titleOf: { _ in "Old" }).title == "Summary of Old")
        #expect(cache.preview(for: a, titleOf: { _ in "New" }).title == "Summary of New")
        #expect(cache.builds == 2)
    }

    @Test func searchAndHomeShareTheCachedPreviews() {
        let cache = ChatPreviewCache()
        let chats = (0..<5).map { chat("v\($0)") }
        let previews = cache.previews(for: chats, titleOf: { _ in nil })
        _ = LibrarySearch.search("what", entries: [], previews: previews)
        _ = cache.previews(for: chats, titleOf: { _ in nil })
        #expect(cache.builds == 5)
    }
}
