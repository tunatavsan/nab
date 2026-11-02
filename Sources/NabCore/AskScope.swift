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
    public static func heading(summary: Bool, question: String?, tally: Tally, title: String?) -> String {
        guard summary else { return question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        if tally.total == 1, let title { return "SUMMARY · " + shortTitle(title).uppercased() }
        return "SUMMARY · " + RackText.count(tally).uppercased()
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

    /// What a held question says while its record is still being read. The same for every kind of record: what
    /// arrives is not known until the capture does.
    public static let waitingLabel = "Waiting for the details…"

    /// What the thinking dots say while the answer is being written: a transcript is read, anything else has only
    /// its details (title, description, kind) to go on. `transcripts` of `total` records have a transcript.
    public static func readingLabel(transcripts: Int, total: Int) -> String {
        if total == 1 { return transcripts == 1 ? "Reading the transcript" : "Reading the details" }
        return transcripts == total ? "Reading \(total) transcripts" : "Reading \(total) items"
    }

    /// The questions offered on an empty chat. For one record with no transcript (a photo, a clip) the questions
    /// that depend on spoken words are left out.
    public static func presets(single: Bool, hasTranscript: Bool) -> [String] {
        guard single else {
            return [
                "Where do these agree, and where do they disagree?",
                "Give each one three bullets.",
                "Which one should I start with, and why?",
            ]
        }
        guard hasTranscript else {
            return [
                "What is this, in a few lines?",
                "What would I need to make something like it?",
                "Which details stand out?",
            ]
        }
        return [
            "What is the main argument, and what backs it up?",
            "List every tool, product and person mentioned.",
            "What should I do differently after this?",
            "Which parts can I skip?",
        ]
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
    public static func resolveHeld(readyCount: Int, failure: String?) -> Resolution {
        if readyCount > 0 { return .send }
        if let failure, !failure.isEmpty { return .fail(failure) }
        return .fail("The details did not arrive. Try again in a moment.")
    }

    /// What `send` does with a question about records in these states.
    public enum SendPlan: Equatable, Sendable {
        case send
        /// A record is still being read: the question waits for it.
        case hold
        /// Nothing can be read and the fetch failed: the chat shows why.
        case fail(String)
        /// Nothing to read and nothing coming.
        case refuse
    }

    /// `timedOut`: a held question has waited as long as it will; it goes with what is ready.
    public static func sendPlan(readyCount: Int, reading: Bool, failure: String?, timedOut: Bool = false) -> SendPlan {
        if reading && !timedOut { return .hold }
        if readyCount > 0 { return .send }
        if let failure, !failure.isEmpty { return .fail(failure) }
        return .refuse
    }

    /// How long a question waits for a record that is still being read.
    public static let holdLimit: TimeInterval = 120

    /// Records a held question names when it goes without them: still being read, or failed by then.
    public static func missingRecords(_ records: [(id: String, hasCapture: Bool, reading: Bool, failed: Bool)])
        -> [String]
    {
        records.filter { !$0.hasCapture && ($0.reading || $0.failed) }.map(\.id)
    }

    /// The failed notes just above the latest question (a time-out note): the floating window shows them with
    /// the answer, since it only draws the last answer.
    public static func notes(in messages: [ChatMessage]) -> [String] {
        guard let question = messages.lastIndex(where: { $0.role == .user }) else { return [] }
        var notes: [String] = []
        var index = question - 1
        while index >= 0, messages[index].role == .assistant, messages[index].failed {
            notes.insert(messages[index].text, at: 0)
            index -= 1
        }
        return notes
    }

    /// The one chat line for records that did not arrive in time.
    public static func missingNote(titles: [String]) -> String {
        let names = titles.map { "“\($0)”" }.joined(separator: ", ")
        return "\(names) did not arrive in time, so this answer leaves \(titles.count == 1 ? "it" : "them") out."
    }

    /// The records an open session offers: those with a capture (even one whose later step failed) and those still
    /// being read. A record with neither is out.
    public static func sessionMembers(_ records: [(id: String, hasCapture: Bool, reading: Bool)]) -> [String] {
        records.filter { $0.hasCapture || $0.reading }.map(\.id)
    }

    /// The records the window asks about. Once something was sent or held, `locked` keeps the window on that chat
    /// whatever the session does; before that the scope follows the session live. Only the picker, or reopening
    /// the window, changes it.
    public static func windowIDs(
        locked: [String]?, pinned: [String]?, scope: AskScope, session: [String], latest: String?
    ) -> [String] {
        locked ?? pinned ?? ids(for: scope, session: session, latest: latest)
    }

    /// What an empty chat shows. It follows the chat's own state; whether a summary may start by itself is a
    /// separate matter (`holdsSummary`).
    public enum EmptyState: Equatable, Sendable {
        case chooser, waiting, reading, summarize
    }

    public static func emptyState(choosing: Bool, providerProblem: Bool, waiting: Bool, busy: Bool) -> EmptyState {
        if choosing || providerProblem { return .chooser }
        if waiting { return .waiting }
        if busy { return .reading }
        return .summarize
    }

    public enum Placement: Equatable, Sendable { case session, latest, pinned }

    /// Which scope a caller's ids are: the session (live, or just its ready part), the latest record, or a pin.
    public static func placement(handed ids: [String], session: [String], readySession: [String], latest: String?)
        -> Placement
    {
        if ids == session || ids == readySession { return .session }
        if let latest, ids == [latest] { return .latest }
        return .pinned
    }

    /// How long after a timecode click a mouse-down elsewhere is taken as part of that click's consequences (the
    /// browser coming forward, a permission prompt, the player opening) and does not close the window.
    public static let citationGrace: TimeInterval = 5

    public static func closesOnOutsideClick(sinceCitation: TimeInterval?) -> Bool {
        guard let sinceCitation else { return true }
        return sinceCitation > citationGrace
    }
}
