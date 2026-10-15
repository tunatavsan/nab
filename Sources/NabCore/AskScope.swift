import Foundation

/// What the floating AI window asks about: the open session, or the newest video of the library.
public enum AskScope: Sendable, Hashable {
    case session
    case latest

    /// The part of an entry the choice of "latest" looks at.
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let addedAt: Date
        public let hasCapture: Bool

        public init(id: String, addedAt: Date, hasCapture: Bool) {
            self.id = id
            self.addedAt = addedAt
            self.hasCapture = hasCapture
        }
    }

    /// The newest entry that has a capture; on a tie the earlier one in the list wins.
    public static func latestID(in entries: [Candidate]) -> String? {
        var best: Candidate?
        for entry in entries where entry.hasCapture {
            if best == nil || entry.addedAt > best!.addedAt { best = entry }
        }
        return best?.id
    }

    /// An empty session starts on the latest video.
    public static func initial(sessionIDs: [String]) -> AskScope { sessionIDs.isEmpty ? .latest : .session }

    public static func ids(for scope: AskScope, session: [String], latest: String?) -> [String] {
        switch scope {
        case .session: session
        case .latest: latest.map { [$0] } ?? []
        }
    }

    /// The picker only makes sense when the session holds several videos and there is a latest one to switch to.
    public static func offersChoice(session: [String], latest: String?) -> Bool {
        session.count > 1 && latest != nil
    }

    public func toggled(offered: Bool) -> AskScope {
        guard offered else { return self }
        return self == .session ? .latest : .session
    }

    /// The small line over the answer: "SUMMARY · 3 VIDEOS", "SUMMARY · LEARN PYTHON", or the question itself.
    public static func heading(summary: Bool, question: String?, count: Int, title: String?) -> String {
        guard summary else { return question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if count == 1, let title { return "SUMMARY · " + shortTitle(title).uppercased() }
        return "SUMMARY · " + RackText.videos(count).uppercased()
    }

    /// The title up to its first dash, colon or bar, at most 32 characters.
    public static func shortTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" – ", " — ", " - ", " | ", ": "] {
            if let range = text.range(of: separator) {
                text = String(text[..<range.lowerBound])
                break
            }
        }
        guard text.count > 32 else { return text }
        return String(text.prefix(31)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The longest text a link may leave in the field.
    public static let maxDraftLength = 2_000

    /// What `nab://ask?q=` puts in the field. A link can come from any web page, so it only fills the field:
    /// the user reads it and presses Return, and nothing is sent to the AI provider without that.
    public static func draft(fromLinkText text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return String(text.prefix(maxDraftLength))
    }
}
