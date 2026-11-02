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

    /// An empty session starts on the latest record. A `focus` (the front tab the shortcut just nabbed) always wins,
    /// even when the session holds others: the question is about what the user is looking at.
    public static func initial(sessionIDs: [String], focus: String? = nil) -> AskScope {
        focus != nil || sessionIDs.isEmpty ? .latest : .session
    }

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

    // MARK: Asking before summarizing

    /// A line of the key hints under the field.
    public struct Hint: Sendable, Equatable {
        public let key: String
        public let label: String
        public let spoken: String
    }

    /// The hints under the field. With nothing said yet ⌘↩ summarizes, so it leads.
    public static func hints(chatIsEmpty: Bool) -> [Hint] {
        var hints: [Hint] = []
        if chatIsEmpty { hints.append(Hint(key: "⌘↩", label: "Summarize", spoken: "Command Return summarizes.")) }
        hints += [
            Hint(key: "esc", label: "Close", spoken: "Escape closes."),
            Hint(key: "⇥", label: "Switch scope", spoken: "Tab switches between this one and the session."),
            Hint(key: "⌘O", label: "Open in library", spoken: "Command O opens the library."),
            Hint(key: "⌘C", label: "Copy answer", spoken: "Command C copies the answer."),
        ]
        return hints
    }

    /// ⌘↩ and the Summarize button only start a summary on an empty chat that is not busy or waiting for a capture.
    public static func canSummarize(chatIsEmpty: Bool, busy: Bool, waiting: Bool) -> Bool {
        chatIsEmpty && !busy && !waiting
    }

    /// What a held question says while its record is still being read.
    public static func waitingLabel(isMedia: Bool) -> String {
        isMedia ? "Waiting for the details…" : "Waiting for the transcript…"
    }

    /// Only a send in the session scope uses the open session up. A question about one record (the front tab, the
    /// latest, a handed-in pin) leaves it open, so the next nab still joins it.
    public static func sendUsesSession(scope: AskScope, pinned: Bool, count: Int) -> Bool {
        scope == .session && !pinned && count > 0
    }

    public enum Resolution: Equatable, Sendable {
        case send
        case fail(String)
    }

    /// What becomes of a question held for a capture: it goes out once any record is ready, and the chat shows the
    /// reason when none will be.
    public static func resolveHeld(readyCount: Int, failure: String?, isMedia: Bool) -> Resolution {
        if readyCount > 0 { return .send }
        if let failure, !failure.isEmpty { return .fail(failure) }
        let what = isMedia ? "details" : "transcript"
        return .fail("The \(what) did not arrive. Try again in a moment.")
    }

    /// How long after a timecode click a mouse-down elsewhere is taken as part of that click's consequences (the
    /// browser coming forward, a permission prompt, the player opening) and does not close the window.
    public static let citationGrace: TimeInterval = 5

    public static func closesOnOutsideClick(sinceCitation: TimeInterval?) -> Bool {
        guard let sinceCitation else { return true }
        return sinceCitation > citationGrace
    }
}
