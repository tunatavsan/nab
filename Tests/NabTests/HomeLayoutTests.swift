import Foundation
import Testing

@testable import NabCore

@Suite("Home layout")
struct HomeLayoutTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private let locale = Locale(identifier: "en_GB")
    /// Thursday 15 Oct 2026, 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_076_400)

    private func entry(_ id: String, hoursAgo: Double, session: String?) -> Entry {
        var e = Entry(
            id: "youtube:\(id)", url: URL(string: "https://youtu.be/\(id)")!,
            addedAt: now.addingTimeInterval(-hoursAgo * 3600))
        e.sessionID = session
        return e
    }

    private func chat(_ ids: [String], question: String = "Why?", answer: String = "Because.") -> Conversation {
        var c = Conversation(entryIDs: ids.map { "youtube:\($0)" })
        c.messages = [
            ChatMessage(role: .user, text: question), ChatMessage(role: .assistant, text: answer, model: "Sonnet 5.5"),
        ]
        return c
    }

    private func layout(
        _ entries: [Entry], chats: [Conversation] = [], open: String? = nil, filter: HomeFilter = .all
    ) -> HomeLayout {
        HomeLayout.build(
            entries: entries, chats: chats, openSessionID: open, filter: filter, now: now, calendar: calendar,
            locale: locale)
    }

    @Test func openSessionIsSeparateFromDays() throws {
        let result = layout(
            [entry("a", hoursAgo: 1, session: "s1"), entry("b", hoursAgo: 5, session: "s2")], open: "s1")
        #expect(result.open?.id == "s1")
        #expect(result.days.count == 1)
        #expect(result.days[0].sessions.map(\.id) == ["s2"])
    }

    @Test func noOpenSessionStartsWithMostRecentDay() {
        let result = layout([entry("a", hoursAgo: 1, session: "s1"), entry("b", hoursAgo: 30, session: "s2")])
        #expect(result.open == nil)
        #expect(result.days.map(\.title) == ["Earlier today", "Yesterday"])
    }

    @Test func dayTitles() {
        let c = calendar
        let today = c.startOfDay(for: now)
        func title(_ back: Int) -> String {
            HomeLayout.dayTitle(
                c.date(byAdding: .day, value: -back, to: today)!, now: now, calendar: c, locale: locale)
        }
        #expect(title(0) == "Earlier today")
        #expect(title(1) == "Yesterday")
        #expect(title(3) == "Monday")
        #expect(title(10).contains("Oct"))
        #expect(!title(10).contains("2026"))
        #expect(title(400).contains("2025"))
    }

    @Test func sessionLabelCountsVideosAndChats() throws {
        let entries = [entry("a", hoursAgo: 5, session: "s"), entry("b", hoursAgo: 5.01, session: "s")]
        let result = layout(entries, chats: [chat(["a", "b"])])
        let session = try #require(result.days.first?.sessions.first)
        #expect(session.label.hasSuffix("· 2 videos · 1 chat"))
        #expect(session.label.hasPrefix("9:59"))
        #expect(layout([entries[0]]).days[0].sessions[0].label.hasSuffix("· 1 video"))
    }

    @Test func chatAttachesToTheSessionHoldingAllItsVideos() throws {
        let entries = [
            entry("a", hoursAgo: 1, session: "s1"), entry("b", hoursAgo: 1.01, session: "s1"),
            entry("c", hoursAgo: 6, session: "s2"),
        ]
        let result = layout(entries, chats: [chat(["a", "b"]), chat(["c"])])
        let s1 = try #require(result.days.flatMap(\.sessions).first { $0.id == "s1" })
        let s2 = try #require(result.days.flatMap(\.sessions).first { $0.id == "s2" })
        #expect(s1.chats.count == 1)
        #expect(s2.chats.count == 1)
    }

    @Test func chatAcrossSessionsStandsAlone() throws {
        let entries = [entry("a", hoursAgo: 1, session: "s1"), entry("c", hoursAgo: 6, session: "s2")]
        let result = layout(entries, chats: [chat(["a", "c"])])
        let sessions = result.days.flatMap(\.sessions)
        let loose = try #require(sessions.first { $0.id.hasPrefix("chat-") })
        #expect(loose.entryIDs.isEmpty)
        #expect(loose.allEntryIDs == ["youtube:a", "youtube:c"])
        #expect(sessions.filter { !$0.id.hasPrefix("chat-") }.allSatisfy { $0.chats.isEmpty })
    }

    @Test func chatsAboutRemovedVideosAreDropped() {
        let result = layout([entry("a", hoursAgo: 1, session: "s1")], chats: [chat(["a", "gone"])])
        #expect(result.days.flatMap(\.sessions).allSatisfy { $0.chats.isEmpty })
    }

    @Test func filterVideosHidesChats() throws {
        let result = layout([entry("a", hoursAgo: 1, session: "s1")], chats: [chat(["a"])], filter: .videos)
        let session = try #require(result.days.first?.sessions.first)
        #expect(session.chats.isEmpty)
        #expect(session.entryIDs == ["youtube:a"])
    }

    @Test func filterChatsHidesVideosAndEmptySessions() throws {
        let entries = [entry("a", hoursAgo: 1, session: "s1"), entry("b", hoursAgo: 2, session: "s2")]
        let result = layout(entries, chats: [chat(["a"])], open: "s2", filter: .chats)
        #expect(result.open == nil)
        let session = try #require(result.days.first?.sessions.first)
        #expect(session.entryIDs.isEmpty)
        #expect(session.allEntryIDs == ["youtube:a"])
        #expect(session.chats.count == 1)
        #expect(result.days.flatMap(\.sessions).count == 1)
    }

    @Test func previewTitleExcerptAndCites() {
        let c = chat(
            ["a", "b"], question: "Animasyon neden takılıyor?",
            answer: "Kaynak **ana** iş parçacığı [2 · 6:12] ve [0:45].")
        let p = ChatPreview(c)
        #expect(p.title == "Animasyon neden takılıyor?")
        #expect(p.excerpt == "Kaynak ana iş parçacığı ve .")
        #expect(p.cites.map(\.label) == ["2 · 6:12", "0:45"])
        #expect(p.messageCount == 2)
        #expect(p.model == "Sonnet 5.5")
    }

    @Test func summaryChatTitle() {
        var c = Conversation(entryIDs: ["youtube:a", "youtube:b", "youtube:c"])
        c.messages = [
            ChatMessage(role: .user, text: "long prompt", isSummaryRequest: true),
            ChatMessage(role: .assistant, text: "ok"),
        ]
        #expect(ChatPreview(c).title == "Summary of 3 videos")
        var one = Conversation(entryIDs: ["youtube:a"])
        one.messages = c.messages
        #expect(ChatPreview(one, titleOf: { _ in "Learn Python" }).title == "Summary of Learn Python")
    }
}
