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
        /// Entries whose saved files are gone; the card offers "Save again" for them.
        var saveAgain: [String] = []
        /// Changes on every update so the toast re-lands even when the text repeats.
        var pulse = 0
    }

    private(set) var entries: [Entry] = []
    private(set) var toast: Toast?
    var inFlight: Int { entries.filter { $0.phase == .fetching || $0.phase == .saving }.count }
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
    /// The fetch or save running for each entry, so removing the entry stops it.
    private var work: [String: Task<Void, Never>] = [:]
    /// How far each entry's photos and clips have arrived, 0…1, while they are being saved. Memory only.
    private(set) var savingProgress: [String: Double] = [:]
    /// Each pending file's share of that progress.
    private var fileProgress: [String: [Int: Double]] = [:]
    /// Library writes, one after another, so a removal can never be overtaken by an earlier save.
    private var writes: Task<Void, Never>?
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
    /// Whether an item that lands may still copy itself (`ClipboardClaim`).
    private var clipboard = ClipboardClaim()
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
        // Files half-arrived when the app quit are thrown away before anything can start saving; the entries they
        // belonged to save them again from the start.
        let folder = MediaFolder.resolve(setting: UserDefaults.standard.string(forKey: MediaFolder.key))
        for file in MediaFolder.leftovers(in: folder, sourceNames: registry.names) {
            try? FileManager.default.removeItem(at: file)
        }
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
        // An entry still fetching when the app quit is fetched again; one still saving saves what is missing.
        for entry in restored where entry.phase == .fetching { fetch(entry.id) }
        for entry in restored where entry.phase == .saving { save(entry.id) }
    }

    /// The shortcut: read the browser's front tab and start fetching it.
    func nabFrontTab() async {
        let registry = registry
        show(.init(tone: .working, title: "Reading the front tab…", detail: ""), hold: true)
        // Read before the tab is fetched: Nab's own copy bumps the count, and a copy by the user must win.
        let mark = Pasteboard.board.changeCount
        switch await BrowserBridge.frontTab(accept: { registry.supports($0) }) {
        case .success(let tab): add(tab.url, title: Self.cleanTitle(tab.title), copyMark: mark)
        case .failure(let error): show(.init(tone: .failed, title: "Nothing to nab", detail: error.message))
        }
    }

    /// Adds every supported link in `text`; for pasting a list of twenty links at once.
    func add(linksIn text: String) {
        let urls = registry.links(in: text)
        for url in urls { add(url, title: nil, announce: urls.count == 1) }
        if urls.count > 1 { show(.init(tone: .working, title: "Nabbing \(urls.count) links", detail: "")) }
        if urls.isEmpty {
            show(.init(tone: .failed, title: "No links to nab", detail: RackText.supportedSources(registry.names)))
        }
    }

    /// Adds the links on the pasteboard.
    func pasteLinks() {
        add(linksIn: Pasteboard.board.string(forType: .string) ?? "")
    }

    func add(_ url: URL, title: String?, announce: Bool = true, copyMark: Int? = nil) {
        guard let match = registry.match(url) else {
            if registry.shortLinkProvider(for: url) != nil {
                expand(url, title: title, announce: announce, copyMark: copyMark)
            } else {
                show(
                    .init(
                        tone: .failed, title: "Nab can't read this link",
                        detail: RackText.supportedSources(registry.names)))
            }
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
            // Files moved or deleted since are saved again; files still in place are not downloaded twice.
            let missing = entry.capture.map { CopyPayload.missing([$0]) } ?? []
            if entry.phase == .ready, !missing.isEmpty {
                forget(missing, in: entry.id)
                save(entry.id)
                return
            }
            if entry.phase == .ready, entry.capture?.holdsNothing == true {
                if announce {
                    show(
                        .init(tone: .working, title: entry.title, detail: "Fetching…", thumbnail: entry.thumbnailURL),
                        hold: true)
                }
                fetch(entry.id)
                return
            }
            if announce {
                let saved = entry.phase == .ready && entry.capture?.isMedia == true
                show(
                    .init(
                        tone: .done, title: entry.title, detail: saved ? "Already saved" : "Already in your session",
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
                .init(tone: .working, title: entry.title, detail: "Fetching…", thumbnail: entry.thumbnailURL),
                hold: true)
        }
        fetch(entry.id)
    }

    /// A share link (`pin.it/…`) names its item only after one request; the full link then takes the usual way in,
    /// so a pin added once by its short link and once by its own link is one entry.
    private func expand(_ url: URL, title: String?, announce: Bool, copyMark: Int?) {
        if announce { show(.init(tone: .working, title: "Opening the link…", detail: url.absoluteString), hold: true) }
        Task {
            if let full = await openedLink(url) { add(full, title: title, announce: announce, copyMark: copyMark) }
        }
    }

    /// A short link's own address, or nil after showing why it could not be opened. Both shortcuts use it, so the
    /// failure reads the same wherever it comes from.
    func openedLink(_ url: URL) async -> URL? {
        do {
            let full = try await registry.expand(url)
            guard registry.match(full) != nil else {
                throw NabError("The link led to \(full.host() ?? "a page") Nab doesn't read.")
            }
            return full
        } catch {
            show(.init(tone: .failed, title: "Couldn't open the link", detail: error.localizedDescription))
            return nil
        }
    }

    /// Tries again: an item made of photos and clips saves only what is missing (its details are kept); anything
    /// else is fetched again.
    func retry(_ id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].failure = nil
        // Files moved or deleted since are saved again.
        if let capture = entries[index].capture, capture.isMedia {
            let gone = CopyPayload.missing([capture])
            if !gone.isEmpty { forget(gone, in: id) }
        }
        if let capture = entries[index].capture, capture.isMedia, capture.media.contains(where: { $0.savedPath == nil })
        {
            persist(entries[index])
            save(id)
        } else {
            fetch(id)
        }
    }

    /// Told which entries were removed, so chats about them stop and go (set by the assistant).
    @ObservationIgnored var onRemove: (Set<String>) -> Void = { _ in }

    /// Removes entries from the library. A fetch or save still running for them stops, and a half-arrived file is
    /// removed with it; files already saved stay, since they are the user's.
    func remove(_ ids: Set<String>) {
        for id in ids {
            work.removeValue(forKey: id)?.cancel()
            fetching.remove(id)
            savingProgress[id] = nil
            fileProgress[id] = nil
            copyMarks[id] = nil
        }
        entries.removeAll { ids.contains($0.id) }
        onRemove(ids)
        write("removing from the library") { store in
            for id in ids {
                try await store.delete(id)
                try await store.deleteConversation(id)
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
            show(.init(tone: .done, title: "New session", detail: "The next link starts a fresh set."))
        }
    }

    /// Puts the session on the clipboard: one context block when anything in it is read as text, else the saved
    /// photos and clips as files. The list stays; the next nab starts a new session.
    func copySession() {
        let captures = trayCaptures
        guard !captures.isEmpty else {
            let shortcut = ShortcutStore.shared.text(for: .nab) ?? "the Nab shortcut"
            show(
                .init(
                    tone: .failed, title: "Nothing to copy yet",
                    detail: "Press \(shortcut) with a \(RackText.list(registry.names, "or")) page in front."))
            return
        }
        guard let payload = copy(session) else { return }
        sessionConsumed = true
        persistSession()
        let pending = session.count - captures.count
        show(
            .init(
                tone: .done, title: RackText.copied(Tally(captures: captures)),
                detail: Self.pasteHint(payload) + (pending > 0 ? " · \(pending) still fetching" : "")))
    }

    /// The one way Nab copies items, wherever the copy starts (the shortcut, a button, a menu, the palette, a record
    /// page, an item that lands): photos and clips as their files, anything read as text as one context pack, and
    /// nothing at all when a saved file is gone. Then the rack says so and offers to save it again, or `onMissing`
    /// does, for a page that shows it in place. `automatic`: an item that landed copies itself, so the next one may
    /// replace it. Returns what went on the clipboard, nil when nothing did.
    @discardableResult
    func copy(_ entries: [Entry], automatic: Bool = false, onMissing: (([Entry]) -> Void)? = nil) -> CopyPayload? {
        let captures = entries.compactMap(\.capture)
        guard !captures.isEmpty else { return nil }
        guard CopyPayload.missing(captures).isEmpty else {
            (onMissing ?? noteMissing)(entries)
            return nil
        }
        let payload = CopyPayload.session(captures)
        Pasteboard.write(payload)
        clipboard.copied(at: Pasteboard.board.changeCount, automatic: automatic)
        return payload
    }

    /// Says that saved files are gone instead of handing over links to nothing, and offers to save them again.
    func noteMissing(_ candidates: [Entry]) {
        let hit = candidates.compactMap { entry in
            entry.capture.map { (entry, CopyPayload.missing([$0])) }
        }.filter { !$0.1.isEmpty }
        guard !hit.isEmpty else { return }
        let detail = hit.count == 1 ? hit[0].0.title : RackText.count(Tally(hit.flatMap(\.1)))
        show(.init(tone: .failed, title: "File moved or deleted", detail: detail, saveAgain: hit.map(\.0.id)))
    }

    /// "Save again" on that card: saves the missing files of each entry.
    func saveAgain(_ ids: [String]) {
        dismissToast()
        for id in ids { retry(id) }
    }

    /// Where a copy goes: "~13k tokens · paste into any AI" for a context pack, Finder or a chat for files.
    private static func pasteHint(_ payload: CopyPayload) -> String {
        switch payload {
        case .text(let text): "~\(thousands(ContextPack.estimatedTokens(text)))k tokens · paste into any AI"
        case .files: "Paste into Finder, Preview or a chat"
        }
    }

    /// The entries a summary should cover: the session's ready captures, or else the latest one. Reading them uses
    /// nothing up; the session counts as used when something is sent about it (`consumeSession`) or copied.
    func sessionSummaryIDs() -> [String] {
        var ids = session.filter { $0.capture != nil }.map(\.id)
        if ids.isEmpty, let latest = entries.first(where: { $0.capture != nil }) { ids = [latest.id] }
        return ids
    }

    /// Something was sent about the whole session: the next nab starts a new one.
    func consumeSession() {
        guard !session.isEmpty else { return }
        sessionConsumed = true
        persistSession()
    }

    private static func thousands(_ tokens: Int) -> String {
        let k = Double(tokens) / 1000
        return k < 10 ? k.formatted(.number.precision(.fractionLength(1))) : Int(k.rounded()).formatted()
    }

    /// Copies a fresh capture when the user asked for it and nothing was copied since nabbing but Nab's own
    /// automatic copy (`ClipboardClaim`): an item read as text as its context, photos and clips as their files once
    /// they are saved.
    private func autoCopy(_ entry: Entry) {
        guard entry.phase == .ready, let mark = copyMarks.removeValue(forKey: entry.id), let capture = entry.capture,
            UserDefaults.standard.bool(forKey: "autoCopy")
        else { return }
        // Compare before copying: the copy itself bumps the count.
        if clipboard.mayAutoCopy(mark: mark, current: Pasteboard.board.changeCount) {
            guard let payload = copy([entry], automatic: true) else { return }
            copiedIDs.insert(entry.id)
            let detail =
                switch payload {
                case .text(let text):
                    "Copied · ~\(Self.thousands(ContextPack.estimatedTokens(text)))k tokens · ⌘V into any AI"
                case .files: "\(RackText.copied(Tally(captures: [capture]))) · ⌘V into Finder or a chat"
                }
            show(.init(tone: .done, title: entry.title, detail: detail, thumbnail: entry.thumbnailURL))
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
        work[id]?.cancel()
        work[id] = Task {
            // Without this, App Nap throttles a menu bar app's network work while it sits in the background.
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Fetching a link")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let result: Result<Capture, Error>
            do { result = .success(try await gate.run { try await provider.fetch(url) }) } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            finish(id, result)
            fetching.remove(id)
        }
    }

    /// Writes an entry's unsaved photos and clips to the media folder, all at once (the downloader's own gate keeps
    /// the count sane). A file already under the item's name at the size it was saved at is kept and not downloaded
    /// again; anything else under that name is left alone and the copy goes next to it.
    private func save(_ id: String) {
        guard let entry = entry(id), let capture = entry.capture, capture.isMedia,
            let provider = registry.provider(for: capture.source)
        else { return }
        let folder = MediaFolder.resolve(setting: UserDefaults.standard.string(forKey: MediaFolder.key))
        let names = MediaFileName.names(for: capture, sourceName: provider.name)
        let pending = capture.media.indices.filter { capture.media[$0].savedPath == nil }
        guard !pending.isEmpty else { return finishSaving(id) }
        savingProgress[id] = 0
        fileProgress[id] = Dictionary(uniqueKeysWithValues: pending.map { ($0, 0.0) })
        work[id]?.cancel()
        work[id] = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Saving media")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            do {
                try await withThrowingTaskGroup(of: (Int, Media).self) { group in
                    for index in pending {
                        let file = folder.appending(path: names[index])
                        group.addTask { [weak self] in
                            let item = try await provider.store(capture.media[index], of: capture, at: file) {
                                received, expected in
                                guard let expected, expected > 0 else { return }
                                let fraction = min(Double(received) / Double(expected), 1)
                                Task { @MainActor in self?.progress(id, index, fraction) }
                            }
                            return (index, item)
                        }
                    }
                    for try await (index, item) in group {
                        progress(id, index, 1)
                        saved(id, index, item)
                    }
                }
                guard !Task.isCancelled else { return }
                finishSaving(id)
            } catch {
                guard !Task.isCancelled else { return }
                savingFailed(id, error)
            }
        }
    }

    private func progress(_ id: String, _ index: Int, _ fraction: Double) {
        guard savingProgress[id] != nil, var files = fileProgress[id] else { return }
        files[index] = fraction
        fileProgress[id] = files
        savingProgress[id] = files.values.reduce(0, +) / Double(max(files.count, 1))
    }

    /// One file is on disk: its path, its size and what it really is go into the entry.
    private func saved(_ id: String, _ index: Int, _ item: Media) {
        guard let at = entries.firstIndex(where: { $0.id == id }),
            entries[at].capture?.media.indices.contains(index) == true
        else { return }
        entries[at].capture?.media[index] = item
        persist(entries[at])
    }

    private func finishSaving(_ id: String) {
        savingProgress[id] = nil
        fileProgress[id] = nil
        work[id] = nil
        guard let entry = entry(id), entry.phase == .ready else { return }
        let remaining = inFlight
        show(
            .init(
                tone: remaining == 0 ? .done : .working, title: entry.title,
                detail: remaining == 0
                    ? "Saved · \(entry.capture.flatMap { RackText.kindLine($0) } ?? "")"
                    : "Saved · \(remaining) more in flight",
                thumbnail: entry.thumbnailURL), hold: remaining > 0)
        autoCopy(entry)
    }

    private func savingFailed(_ id: String, _ error: any Error) {
        savingProgress[id] = nil
        fileProgress[id] = nil
        work[id] = nil
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].failure = "Couldn't save: \(error.localizedDescription)"
        persist(entries[index])
        copyMarks[id] = nil
        let entry = entries[index]
        show(.init(tone: .failed, title: entry.title, detail: entry.failure ?? "", thumbnail: entry.thumbnailURL))
    }

    /// Clears the saved paths of files that are gone, so they are saved again.
    private func forget(_ gone: [Media], in id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }), var capture = entries[index].capture else {
            return
        }
        // The size stays: a file found again under the same name counts only at the size it was saved at.
        for i in capture.media.indices where gone.contains(capture.media[i]) {
            capture.media[i].savedPath = nil
        }
        entries[index].capture = capture
        persist(entries[index])
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
        case .success(var capture):
            // Fetching again keeps the files already saved for the same copies.
            if let old = entries[index].capture?.media {
                for i in capture.media.indices {
                    if let same = old.first(where: { $0.url == capture.media[i].url && $0.savedPath != nil }) {
                        capture.media[i].savedPath = same.savedPath
                        capture.media[i].byteCount = same.byteCount
                    }
                }
            }
            entries[index].capture = capture
        case .failure(let error): entries[index].failure = error.localizedDescription
        }
        let entry = entries[index]
        persist(entry)
        if entry.phase == .failed { copyMarks[id] = nil }
        if entry.phase == .saving {
            show(
                .init(
                    tone: .working, title: entry.title,
                    detail: "Saving \(entry.capture.map { RackText.count(Tally($0.media)) } ?? "")…",
                    thumbnail: entry.thumbnailURL), hold: true)
            save(id)
            return
        }

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
        write("saving \(entry.title)") { try await $0.save(entry) }
    }

    /// Runs library writes in the order they were asked for: each waits for the one before it.
    private func write(_ action: String, _ operation: @escaping @Sendable (LibraryStore) async throws -> Void) {
        let store = store
        let previous = writes
        writes = Task {
            await previous?.value
            do {
                try await operation(store)
            } catch {
                report(error, while: action)
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

    func show(_ next: Toast, hold: Bool = false) {
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
