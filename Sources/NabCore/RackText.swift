import Foundation

/// The words on the session rack under the menu bar icon, kept apart from the view so they can be tested.
public enum RackText {
    public struct Hint: Equatable, Sendable {
        public let action: ShortcutAction
        public let label: String
    }

    /// The shortcut hints in the rack footer, without the shortcuts the system refused or the user cleared.
    public static func hints(map: ShortcutMap, unavailable: Set<ShortcutAction>) -> [Hint] {
        [
            Hint(action: .copySession, label: "Copy all"),
            Hint(action: .summarize, label: "Ask AI"),
            Hint(action: .newSession, label: "New session"),
        ].filter { !unavailable.contains($0.action) && map.combo(for: $0.action) != nil }
    }

    /// "Session · 3 videos".
    public static func header(count: Int) -> String {
        "Session · \(count) video\(count == 1 ? "" : "s")"
    }

    /// "3 videos".
    public static func videos(_ count: Int) -> String {
        "\(count) video\(count == 1 ? "" : "s")"
    }

    /// "2 videos and 3 photos", "4 photos", "1 video": every kind there is, in a fixed order.
    public static func count(_ tally: Tally) -> String {
        let parts = [
            noun(tally.videos, "video"), noun(tally.photos, "photo"), noun(tally.items, "item"),
        ].compactMap { $0 }
        return parts.isEmpty ? "0 items" : list(parts)
    }

    /// "Copied 4 photos".
    public static func copied(_ tally: Tally) -> String { "Copied \(count(tally))" }

    /// One photo or clip: "Photo · 2400×3600", "Video · 1080×1920 · 0:42".
    public static func mediaLine(_ media: Media) -> String {
        var parts = [media.kind == .video ? "Video" : "Photo"]
        if let w = media.width, let h = media.height { parts.append("\(w)×\(h)") }
        if let d = media.duration { parts.append(Timecode.string(d)) }
        return parts.joined(separator: " · ")
    }

    /// The kind line on a card for an item made of photos and clips: "Photo · 2400×3600", "Video · 0:42",
    /// "4 photos", or "Saving… 42%" while its files arrive. Nil for an item read as text, whose card says more.
    public static func kindLine(_ capture: Capture, saving progress: Double? = nil) -> String? {
        guard capture.isMedia else { return nil }
        if let progress { return "Saving… \(Int((min(max(progress, 0), 1) * 100).rounded(.down)))%" }
        guard capture.media.count == 1, let only = capture.media.first else { return count(Tally(capture.media)) }
        if only.kind == .video, let d = only.duration ?? capture.duration { return "Video · \(Timecode.string(d))" }
        return mediaLine(only)
    }

    /// "Nab reads YouTube and Pinterest links."
    public static func supportedSources(_ names: [String]) -> String {
        "Nab reads \(list(names)) links."
    }

    /// "a", "a and b", "a, b and c".
    public static func list(_ items: [String]) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
    }

    private static func noun(_ n: Int, _ word: String) -> String? { n > 0 ? "\(n) \(word)\(n == 1 ? "" : "s")" : nil }

    /// About one token per four characters, the same rule the context pack uses.
    public static func estimatedTokens(characters: Int) -> Int { characters / 4 }

    /// "~13k tokens", "~1.2k tokens" or "~800 tokens".
    public static func tokens(_ count: Int) -> String {
        guard count >= 1000 else { return "~\(count) tokens" }
        let thousands = Double(count) / 1000
        let text =
            thousands < 10
            ? thousands.formatted(.number.precision(.fractionLength(1)).locale(Locale(identifier: "en_US")))
            : Int(thousands.rounded()).formatted(.number.locale(Locale(identifier: "en_US")))
        return "~\(text)k tokens"
    }

    /// "Turkish · ~13k tokens"; either part may be missing.
    public static func detail(language: String?, tokens count: Int?) -> String {
        [language, count.map(tokens)].compactMap { $0 }.joined(separator: " · ")
    }

    /// The headline of a finished card: where the context went, or just that it is ready.
    public static func clipboardTitle(copied: Bool) -> String {
        copied ? "On clipboard · ⌘V into any AI" : "Ready"
    }

    /// How many saved videos from today sit outside the open session.
    public static func earlierTodayCount(
        _ entries: [Entry], now: Date = .now, calendar: Calendar = .current
    ) -> Int {
        entries.filter { !$0.inTray && calendar.isDate($0.addedAt, inSameDayAs: now) }.count
    }

    /// "Earlier today · 4 videos".
    public static func earlierToday(count: Int) -> String {
        "Earlier today · \(videos(count))"
    }

    /// The line under "Session · 3 videos" on the stacked card.
    public static func stackSubtitle(copied: Bool) -> String {
        copied ? "Latest one is on your clipboard" : "Copy all puts them on your clipboard"
    }
}

/// How many of each kind a set of items holds. An item read as text is a video; an item made of photos and clips
/// counts each of them; an item still being fetched is an item.
public struct Tally: Equatable, Sendable {
    public var videos = 0
    public var photos = 0
    public var items = 0

    public init(videos: Int = 0, photos: Int = 0, items: Int = 0) {
        self.videos = videos
        self.photos = photos
        self.items = items
    }

    public init(_ media: [Media]) {
        for m in media {
            if m.kind == .video { videos += 1 } else { photos += 1 }
        }
    }

    public init(_ entries: [Entry]) {
        for entry in entries {
            guard let capture = entry.capture else {
                items += 1
                continue
            }
            if capture.isMedia { self = self + Tally(capture.media) } else { videos += 1 }
        }
    }

    public init(captures: [Capture]) {
        for capture in captures {
            if capture.isMedia { self = self + Tally(capture.media) } else { videos += 1 }
        }
    }

    public var total: Int { videos + photos + items }

    public static func + (a: Tally, b: Tally) -> Tally {
        Tally(videos: a.videos + b.videos, photos: a.photos + b.photos, items: a.items + b.items)
    }
}
