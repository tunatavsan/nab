import Foundation

/// What the home page lists.
public enum HomeFilter: Hashable, Sendable {
    case all, videos, chats
}

/// A saved chat as a card shows it.
public struct ChatPreview: Identifiable, Sendable, Hashable {
    public struct Cite: Hashable, Sendable {
        /// 1-based position among the chat's videos; nil with one video.
        public let video: Int?
        public let seconds: TimeInterval
        public var label: String {
            (video.map { "\($0) · " } ?? "") + Timecode.string(seconds)
        }
    }

    public let id: String
    public let entryIDs: [String]
    public let title: String
    /// The first words of the last answer, markup and citations removed.
    public let excerpt: String
    public let cites: [Cite]
    public let messageCount: Int
    public let model: String?
    public let updatedAt: Date

    /// `titleOf` names an entry; it is used for the title of a summary chat about one video.
    public init(_ chat: Conversation, titleOf: (String) -> String? = { _ in nil }) {
        id = chat.id
        entryIDs = chat.entryIDs
        messageCount = chat.messages.count
        updatedAt = chat.updatedAt
        let answer = chat.messages.last { $0.role == .assistant && !$0.failed && !$0.text.isEmpty }
        model = answer?.model
        excerpt = Self.plain(answer?.text ?? "")
        cites = answer.map { Self.cites(in: $0.text) } ?? []
        if let question = chat.messages.first(where: { $0.role == .user && !$0.isSummaryRequest }) {
            title = Self.plain(question.text)
        } else if chat.entryIDs.count == 1, let name = titleOf(chat.entryIDs[0]) {
            title = "Summary of \(name)"
        } else {
            let n = chat.entryIDs.count
            title = "Summary of \(n) video\(n == 1 ? "" : "s")"
        }
    }

    static func plain(_ text: String) -> String {
        var result = text.replacing(
            /\[(?:\d{1,2}\s*[·,]?\s+)?\d{1,2}(?::\d{2}){1,2}(?:\s*[–—-]\s*\d{1,2}(?::\d{2}){1,2})?\]/, with: "")
        result = result.replacing(/[*_`#>]+/, with: "")
        result = result.replacing(/\s+/, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Up to two distinct timecodes quoted in an answer.
    static func cites(in text: String) -> [Cite] {
        var found: [Cite] = []
        for match in text.matches(of: /\[(?:(\d{1,2})\s*[·,]?\s+)?(\d{1,2}(?::\d{2}){1,2})/) {
            guard let seconds = Citation.seconds(match.output.2) else { continue }
            let cite = Cite(video: match.output.1.flatMap { Int($0) }, seconds: seconds)
            if !found.contains(cite) { found.append(cite) }
            if found.count == 2 { break }
        }
        return found
    }
}

/// Previews of saved chats, rebuilt only when a chat changes: building one runs four regex passes over its
/// last answer, and the home page and the search palette ask for every chat on every redraw.
/// A chat is the same while its `updatedAt`, its message count and (for a one-video chat) the video's title are.
public final class ChatPreviewCache {
    private struct Stamp: Equatable {
        let updatedAt: Date
        let messageCount: Int
        let videoTitle: String?
    }

    private var stored: [String: (stamp: Stamp, preview: ChatPreview)] = [:]
    /// How many previews were built rather than reused; for tests.
    public private(set) var builds = 0

    public init() {}

    public func preview(for chat: Conversation, titleOf: (String) -> String? = { _ in nil }) -> ChatPreview {
        let stamp = Stamp(
            updatedAt: chat.updatedAt, messageCount: chat.messages.count,
            videoTitle: chat.entryIDs.count == 1 ? titleOf(chat.entryIDs[0]) : nil)
        if let hit = stored[chat.id], hit.stamp == stamp { return hit.preview }
        let preview = ChatPreview(chat, titleOf: titleOf)
        stored[chat.id] = (stamp, preview)
        builds += 1
        return preview
    }

    /// Previews of the chats that have messages, in the order given.
    public func previews(for chats: [Conversation], titleOf: (String) -> String? = { _ in nil }) -> [ChatPreview] {
        chats.filter { !$0.messages.isEmpty }.map { preview(for: $0, titleOf: titleOf) }
    }
}

/// One session on the home page: its videos and the chats about them.
public struct HomeSession: Identifiable, Sendable, Hashable {
    public let id: String
    public let start: Date
    public let isOpen: Bool
    /// The videos shown, newest first.
    public let entryIDs: [String]
    /// Every video of the session, whatever the filter hides; what a click opens.
    public let allEntryIDs: [String]
    public let chats: [ChatPreview]
    /// "14:02 · 2 videos · 1 chat".
    public let label: String
}

/// A calendar day of sessions, newest first.
public struct HomeDay: Identifiable, Sendable, Hashable {
    public let id: Date
    public let title: String
    public let sessions: [HomeSession]
}

public struct HomeLayout: Sendable, Hashable {
    /// The session open now; nil when there is none or the filter hides all of it.
    public let open: HomeSession?
    public let days: [HomeDay]

    public static func build(
        entries: [Entry], chats: [Conversation], openSessionID: String?, filter: HomeFilter = .all,
        now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> HomeLayout {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previews = chats.filter { !$0.entryIDs.isEmpty && !$0.messages.isEmpty }.map {
            ChatPreview($0, titleOf: { byID[$0]?.title })
        }
        return build(
            entries: entries, previews: previews, openSessionID: openSessionID, filter: filter, now: now,
            calendar: calendar, locale: locale)
    }

    /// Same, from previews that are already built (see `ChatPreviewCache`).
    public static func build(
        entries: [Entry], previews: [ChatPreview], openSessionID: String?, filter: HomeFilter = .all,
        now: Date = .now, calendar: Calendar = .current, locale: Locale = .current
    ) -> HomeLayout {
        let known = Set(entries.map(\.id))
        let groups = SessionGrouping.groups(entries).filter { !$0.entryIDs.isEmpty }
        let members = groups.map { Set($0.entryIDs) }
        var attached: [String: [ChatPreview]] = [:]
        var loose: [ChatPreview] = []
        for preview in previews where !preview.entryIDs.isEmpty && preview.messageCount > 0 {
            guard preview.entryIDs.allSatisfy(known.contains) else { continue }
            let ids = Set(preview.entryIDs)
            if let index = members.firstIndex(where: { ids.isSubset(of: $0) }) {
                attached[groups[index].id, default: []].append(preview)
            } else {
                loose.append(preview)
            }
        }
        func session(_ id: String, _ start: Date, _ ids: [String], _ chats: [ChatPreview], open: Bool) -> HomeSession? {
            let shownVideos = filter == .chats ? [] : ids
            let shownChats = (filter == .videos ? [] : chats).sorted { $0.updatedAt > $1.updatedAt }
            guard !shownVideos.isEmpty || !shownChats.isEmpty else { return nil }
            return HomeSession(
                id: id, start: start, isOpen: open, entryIDs: shownVideos, allEntryIDs: ids, chats: shownChats,
                label: label(start, videos: shownVideos.count, chats: shownChats.count, calendar, locale))
        }
        var open: HomeSession?
        var buckets: [Date: [HomeSession]] = [:]
        for group in groups {
            let isOpen = group.id == openSessionID
            guard
                let built = session(
                    group.id, group.start, group.entryIDs, attached[group.id] ?? [], open: isOpen)
            else { continue }
            if isOpen {
                open = built
            } else {
                buckets[calendar.startOfDay(for: group.end), default: []].append(built)
            }
        }
        if filter != .videos {
            for chat in loose {
                let ids = chat.entryIDs
                guard let built = session("chat-" + chat.id, chat.updatedAt, ids, [chat], open: false) else { continue }
                // A chat across sessions has no videos of its own on the page.
                let only = HomeSession(
                    id: built.id, start: built.start, isOpen: false, entryIDs: [], allEntryIDs: ids, chats: [chat],
                    label: label(chat.updatedAt, videos: 0, chats: 1, calendar, locale))
                buckets[calendar.startOfDay(for: chat.updatedAt), default: []].append(only)
            }
        }
        let days = buckets.keys.sorted(by: >).map { day in
            HomeDay(
                id: day, title: dayTitle(day, now: now, calendar: calendar, locale: locale),
                sessions: (buckets[day] ?? []).sorted { ($0.start, $0.id) > ($1.start, $1.id) })
        }
        return HomeLayout(open: open, days: days)
    }

    /// "Earlier today", "Yesterday", the weekday within the last week, else the date.
    public static func dayTitle(_ day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let today = calendar.startOfDay(for: now)
        let ago = calendar.dateComponents([.day], from: day, to: today).day ?? 0
        var style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch ago {
        case ...0: return "Earlier today"
        case 1: return "Yesterday"
        case 2...6: return day.formatted(style.weekday(.wide))
        default:
            style = style.day().month(.abbreviated)
            if !calendar.isDate(day, equalTo: today, toGranularity: .year) { style = style.year() }
            return day.formatted(style)
        }
    }

    static func label(_ start: Date, videos: Int, chats: Int, _ calendar: Calendar, _ locale: Locale) -> String {
        var parts = [
            start.formatted(
                Date.FormatStyle(
                    date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                    timeZone: calendar.timeZone))
        ]
        if videos > 0 { parts.append("\(videos) video\(videos == 1 ? "" : "s")") }
        if chats > 0 { parts.append("\(chats) chat\(chats == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}
