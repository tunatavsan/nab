import AppKit
import NabCore
import Observation

/// Owns the library entries, the fetches in flight, and the capture toast.
@MainActor
@Observable
final class CaptureCenter {
    struct Toast: Equatable {
        enum Tone { case working, done, failed }
        var tone: Tone
        var title: String
        var detail: String
        var thumbnail: URL?
        /// Changes on every update so the toast re-lands even when the text repeats.
        var pulse = 0
    }

    private(set) var entries: [Entry] = []
    private(set) var toast: Toast?
    var inFlight: Int { entries.filter { $0.phase == .fetching }.count }
    var tray: [Entry] { entries.filter(\.inTray) }
    /// The open session's entries, newest first. `inTray` means "in the open session".
    var session: [Entry] { tray }
    var trayCaptures: [Capture] { tray.compactMap(\.capture) }

    init() { UserDefaults.standard.register(defaults: ["autoCopy": true]) }

    let registry = SourceRegistry.standard
    let store = LibraryStore()
    private let gate = Gate(limit: 6)
    private var toastDismissal: Task<Void, Never>?
    /// True while the pointer is over the rack, which then stays until the pointer leaves.
    private var toastHovered = false
    private var fetching: Set<String> = []
    /// False when the system refused the global shortcut, so the interface stops advertising it.
    var shortcutAvailable = true

    /// The open capture session: the videos nabbed in one burst, copied together into one AI conversation.
    private(set) var sessionID: String?
    /// True once the session was copied or summarized; the next nab starts a new one.
    private(set) var sessionConsumed = false
    private(set) var sessionLastActivity: Date?
    /// Entries whose context the auto-copy already put on the clipboard.
    private(set) var copiedIDs: Set<String> = []
    /// Seconds without a nab after which the open session closes by itself; the "sessionIdleMinutes" setting.
    static var sessionIdle: TimeInterval {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["sessionIdleMinutes": 5])
        return TimeInterval(min(max(defaults.integer(forKey: "sessionIdleMinutes"), 1), 60) * 60)
    }
    private var idleTask: Task<Void, Never>?
    /// Pasteboard change counts recorded when a nab began, per entry waiting for its auto-copy.
    private var copyMarks: [String: Int] = [:]
    /// The pasteboard change count right after Nab's own last copy, so a later auto-copy may replace it.
    private var ownCopyCount: Int?
    private static let sessionKey = "session"

    private struct SessionState: Codable {
        var id: String?
        var consumed: Bool
        var lastActivity: Date?
    }

    /// How long `nab://chat` waits for transcripts before it summarizes what has arrived.
    static let fetchWaitTimeout: Duration = .seconds(15)

    func load() async {
        restoreSession()
        let saved = await store.loadAll()
        // Links opened with the app (a nab:// URL, the shortcut) can arrive while the library is read; they are
        // newer, so they stay on top and their saved copies are skipped.
        let added = Set(entries.map(\.id))
        let restored = saved.filter { !added.contains($0.id) }
        entries += restored
        // Entries left in a session that no longer exists drop out of the tray.
        for index in entries.indices
        where entries[index].inTray && (sessionID == nil || entries[index].sessionID != sessionID) {
            entries[index].inTray = false
            persist(entries[index])
        }
        // An entry still fetching when the app quit is fetched again.
        for entry in restored where entry.phase == .fetching { fetch(entry.id) }
    }

    /// The shortcut: read the browser's front tab and start fetching it.
    func nabFrontTab() async {
        let registry = registry
        show(.init(tone: .working, title: "Reading the front tab…", detail: ""), hold: true)
        // Read before the tab is fetched: Nab's own copy bumps the count, and a copy by the user must win.
        let mark = NSPasteboard.general.changeCount
        switch await BrowserBridge.frontTab(accept: { registry.match($0) != nil }) {
        case .success(let tab): add(tab.url, title: Self.cleanTitle(tab.title), copyMark: mark)
        case .failure(let error): show(.init(tone: .failed, title: "Nothing to nab", detail: error.message))
        }
    }

    /// Adds every supported link in `text`; for pasting a list of twenty videos at once.
    func add(linksIn text: String) {
        let urls = registry.links(in: text)
        for url in urls { add(url, title: nil, announce: urls.count == 1) }
        if urls.count > 1 { show(.init(tone: .working, title: "Nabbing \(urls.count) videos", detail: "")) }
        if urls.isEmpty {
            show(.init(tone: .failed, title: "No video links found", detail: "Copy one or more YouTube links first."))
        }
    }

    /// Adds the links on the pasteboard.
    func pasteLinks() {
        add(linksIn: NSPasteboard.general.string(forType: .string) ?? "")
    }

    func add(_ url: URL, title: String?, announce: Bool = true, copyMark: Int? = nil) {
        guard let match = registry.match(url) else {
            show(.init(tone: .failed, title: "Nab can't read this link yet", detail: url.host() ?? url.absoluteString))
            return
        }
        let now = Date.now
        if SessionGrouping.shouldStartNewSession(
            now: now, lastActivity: sessionLastActivity, consumed: sessionConsumed, hasSession: sessionID != nil,
            idle: Self.sessionIdle)
        {
            closeSession()
            sessionID = "s-\(Int(now.timeIntervalSince1970 * 1000))"
        }
        sessionLastActivity = now
        scheduleIdleClose()
        persistSession()
        if let copyMark { copyMarks[match.entryID] = copyMark }
        if let index = entries.firstIndex(where: { $0.id == match.entryID }) {
            var entry = entries.remove(at: index)
            entry.addedAt = .now
            entry.inTray = true
            entry.sessionID = sessionID
            entries.insert(entry, at: 0)
            persist(entry)
            if entry.phase == .failed { retry(entry.id) }
            if announce {
                show(
                    .init(
                        tone: .done, title: entry.title, detail: "Already in your session",
                        thumbnail: entry.thumbnailURL))
            }
            if entry.phase == .ready { autoCopy(entry) }
            return
        }
        var entry = Entry(id: match.entryID, url: url, provisionalTitle: title)
        entry.sessionID = sessionID
        entries.insert(entry, at: 0)
        persist(entry)
        if announce {
            show(
                .init(
                    tone: .working, title: entry.title, detail: "Fetching transcript…", thumbnail: entry.thumbnailURL),
                hold: true)
        }
        fetch(entry.id)
    }

    func retry(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].failure = nil
        fetch(id)
    }

    /// Told which entries were removed, so chats about them stop and go (set by the assistant).
    @ObservationIgnored var onRemove: (Set<String>) -> Void = { _ in }

    func remove(_ ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
        onRemove(ids)
        let store = store
        Task {
            do {
                for id in ids {
                    try await store.delete(id)
                    try await store.deleteConversation(id)
                }
            } catch {
                report(error, while: "removing from the library")
            }
        }
    }

    func entry(_ id: String) -> Entry? { entries.first { $0.id == id } }

    func setAISummary(_ text: String, model: String, for id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].capture != nil else { return }
        entries[index].capture?.aiSummary = text
        entries[index].capture?.aiModel = model
        persist(entries[index])
    }

    func removeFromTray(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].inTray = false
        persist(entries[index])
    }

    /// Empties the tray; the entries stay in the library.
    func clearTray() {
        for index in entries.indices where entries[index].inTray {
            entries[index].inTray = false
            persist(entries[index])
        }
    }

    func copyTray() { copySession() }

    // MARK: Session

    /// Ends the open session; its entries stay in the library. The next nab starts a new one.
    func closeSession(announce: Bool = false) {
        clearTray()
        sessionID = nil
        sessionConsumed = false
        sessionLastActivity = nil
        copiedIDs = []
        idleTask?.cancel()
        idleTask = nil
        persistSession()
        if announce {
            show(.init(tone: .done, title: "New session", detail: "The next video starts a fresh set."))
        }
    }

    /// Puts the session's ready captures on the clipboard as one context block. The list stays; the next nab
    /// starts a new session.
    func copySession() {
        let captures = trayCaptures
        guard !captures.isEmpty else {
            show(
                .init(
                    tone: .failed, title: "Nothing to copy yet",
                    detail: "Press \(ShortcutStore.shared.text(for: .nab) ?? "the Nab shortcut") with a video in front."
                ))
            return
        }
        let text = ContextPack.render(captures)
        Pasteboard.copy(text)
        ownCopyCount = NSPasteboard.general.changeCount
        sessionConsumed = true
        persistSession()
        let pending = session.count - captures.count
        show(
            .init(
                tone: .done, title: "Copied \(captures.count) video\(captures.count == 1 ? "" : "s")",
                detail: "~\(Self.thousands(ContextPack.estimatedTokens(text)))k tokens · paste into any AI"
                    + (pending > 0 ? " · \(pending) still fetching" : "")))
    }

    /// The entries a summary should cover: the session's ready captures, or else the latest one.
    func sessionSummaryIDs() -> [String] {
        var ids = session.filter { $0.capture != nil }.map(\.id)
        if ids.isEmpty, let latest = entries.first(where: { $0.capture != nil }) { ids = [latest.id] }
        if !ids.isEmpty {
            sessionConsumed = true
            persistSession()
        }
        return ids
    }

    private static func thousands(_ tokens: Int) -> String {
        let k = Double(tokens) / 1000
        return k < 10 ? k.formatted(.number.precision(.fractionLength(1))) : Int(k.rounded()).formatted()
    }

    /// Copies a fresh capture's context when the user asked for it and has not copied anything since nabbing.
    private func autoCopy(_ entry: Entry) {
        guard let mark = copyMarks.removeValue(forKey: entry.id), let capture = entry.capture,
            UserDefaults.standard.bool(forKey: "autoCopy")
        else { return }
        // Compare before copying: the copy itself bumps the count. Nab's own earlier copy may be replaced, so
        // nabbing several videos in a row leaves the latest one on the clipboard.
        let current = NSPasteboard.general.changeCount
        if current == mark || current == ownCopyCount {
            let text = ContextPack.render([capture])
            Pasteboard.copy(text)
            ownCopyCount = NSPasteboard.general.changeCount
            copiedIDs.insert(entry.id)
            show(
                .init(
                    tone: .done, title: entry.title,
                    detail: "Copied · ~\(Self.thousands(ContextPack.estimatedTokens(text)))k tokens · ⌘V into any AI",
                    thumbnail: entry.thumbnailURL))
        } else {
            show(
                .init(
                    tone: .done, title: entry.title,
                    detail:
                        "Ready · clipboard changed, \(ShortcutStore.shared.text(for: .copySession) ?? "Copy all") copies the session",
                    thumbnail: entry.thumbnailURL))
        }
    }

    private func scheduleIdleClose() {
        idleTask?.cancel()
        let remaining = max(0, Self.sessionIdle - Date.now.timeIntervalSince(sessionLastActivity ?? .now))
        idleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            self?.closeSession()
        }
    }

    private func persistSession() {
        let state = SessionState(id: sessionID, consumed: sessionConsumed, lastActivity: sessionLastActivity)
        UserDefaults.standard.set(try? JSONEncoder().encode(state), forKey: Self.sessionKey)
    }

    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.sessionKey),
            let state = try? JSONDecoder().decode(SessionState.self, from: data),
            let id = state.id, let last = state.lastActivity,
            Date.now.timeIntervalSince(last) <= Self.sessionIdle
        else { return }
        // A session opened by a nab that arrived while the library loaded wins over the saved one.
        guard sessionID == nil else { return }
        sessionID = id
        sessionConsumed = state.consumed
        sessionLastActivity = last
        scheduleIdleClose()
    }

    private func fetch(_ id: String) {
        guard let entry = entry(id), let provider = registry.match(entry.url)?.provider else { return }
        let url = entry.url
        let gate = gate
        fetching.insert(id)
        Task {
            // Without this, App Nap throttles a menu bar app's network work while it sits in the background.
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiated, reason: "Fetching a transcript")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let result: Result<Capture, Error>
            do { result = .success(try await gate.run { try await provider.fetch(url) }) } catch {
                result = .failure(error)
            }
            finish(id, result)
            fetching.remove(id)
        }
    }

    /// Returns when the fetches for `ids` have finished, or after `timeout`, whichever comes first.
    func waitForFetches(_ ids: [String], timeout: Duration = CaptureCenter.fetchWaitTimeout) async {
        // Polls rather than awaiting the fetch tasks: awaiting a task's value ignores cancellation, so a timeout
        // could not cut it short.
        let deadline = ContinuousClock.now + timeout
        while ids.contains(where: fetching.contains), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func finish(_ id: String, _ result: Result<Capture, Error>) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let capture): entries[index].capture = capture
        case .failure(let error): entries[index].failure = error.localizedDescription
        }
        let entry = entries[index]
        persist(entry)
        if entry.phase == .failed { copyMarks[id] = nil }

        let remaining = inFlight
        switch (entry.phase, remaining) {
        case (.failed, _):
            show(
                .init(
                    tone: .failed, title: entry.title, detail: entry.failure ?? "Failed", thumbnail: entry.thumbnailURL)
            )
        case (_, 0):
            show(.init(tone: .done, title: entry.title, detail: entry.metaLine, thumbnail: entry.thumbnailURL))
            autoCopy(entry)
        default:
            show(
                .init(
                    tone: .working, title: entry.title, detail: "Done · \(remaining) more in flight",
                    thumbnail: entry.thumbnailURL), hold: true)
            autoCopy(entry)
        }
    }

    private func persist(_ entry: Entry) {
        let store = store
        Task {
            do {
                try await store.save(entry)
            } catch {
                report(error, while: "saving \(entry.title)")
            }
        }
    }

    /// Shows a failure to read or write the library, which the user would otherwise not notice until the
    /// data is missing.
    func report(_ error: any Error, while action: String) {
        NSLog("Nab: failed \(action): \(error)")
        show(.init(tone: .failed, title: "Couldn't finish \(action)", detail: error.localizedDescription))
    }

    // MARK: Toast

    private func show(_ next: Toast, hold: Bool = false) {
        var next = next
        next.pulse = (toast?.pulse ?? 0) + 1
        toast = next
        toastDismissal?.cancel()
        guard !hold, !toastHovered else { return }
        scheduleDismissal(after: next.tone == .failed ? 3.6 : 2.2)
    }

    private func scheduleDismissal(after seconds: Double) {
        toastDismissal?.cancel()
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.toast = nil
            self?.toastHovered = false
        }
    }

    /// The pointer entered or left the rack: it stays while hovered and goes a moment after the pointer leaves.
    func holdToast(_ hovering: Bool) {
        toastHovered = hovering && toast != nil
        guard toast != nil else { return }
        if hovering {
            toastDismissal?.cancel()
        } else if inFlight == 0 {
            // While fetches run the next update schedules the dismissal itself.
            scheduleDismissal(after: 1.5)
        }
    }

    func dismissToast() {
        toastDismissal?.cancel()
        toastHovered = false
        toast = nil
    }

    /// "(3) Title - YouTube" → "Title".
    static func cleanTitle(_ title: String?) -> String? {
        guard var title, !title.isEmpty else { return nil }
        if let range = title.range(of: #"^\(\d+\)\s*"#, options: .regularExpression) { title.removeSubrange(range) }
        if title.hasSuffix(" - YouTube") { title.removeLast(" - YouTube".count) }
        return title
    }
}
