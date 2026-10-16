import Foundation

/// A YouTube video id. Every player target builds its address or script from one that passed this check.
public enum YouTubeID {
    public static func isValid(_ id: String) -> Bool {
        id.utf8.count == 11
            && id.utf8.allSatisfy {
                ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x5F || $0 == 0x2D
            }
    }

    /// The id inside a library entry id such as `youtube:dQw4w9WgXcQ`; nil for any other source or a malformed id.
    public static func id(fromEntryID entryID: String) -> String? {
        let prefix = "youtube:"
        guard entryID.hasPrefix(prefix) else { return nil }
        let id = String(entryID.dropFirst(prefix.count))
        return isValid(id) ? id : nil
    }
}

/// Where a click on a timecode may go, in the order the router tries them.
public enum PlaybackTarget: Hashable, Sendable {
    /// Nab's own small player.
    case mini
    /// The matching browser tab: set the playback position with a script.
    case tabScript
    /// The matching browser tab: change its address to the moment (needs no "JavaScript from Apple Events").
    case tabAddress
    /// A new browser tab; the last resort.
    case newTab
}

public enum PlaybackPlan {
    public enum Setting: String, Sendable {
        case nab, browser

        public init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .nab }
    }

    /// `tabMatch` and `jsAllowed` are nil while unknown; the router learns them from the first browser attempt
    /// and asks again.
    public static func targets(
        setting: Setting, embedFailed: Bool, tabMatch: Bool? = nil, jsAllowed: Bool? = nil
    ) -> [PlaybackTarget] {
        var browser: [PlaybackTarget] = []
        if tabMatch != false {
            if jsAllowed != false { browser.append(.tabScript) }
            browser.append(.tabAddress)
        }
        browser.append(.newTab)
        return setting == .nab && !embedFailed ? [.mini] + browser : browser
    }
}
