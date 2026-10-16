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
