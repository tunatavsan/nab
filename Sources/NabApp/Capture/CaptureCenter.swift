import AppKit
import NabCore
import NabYouTube
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
    var trayCaptures: [Capture] { tray.compactMap(\.capture) }

    let registry = SourceRegistry([YouTubeSource()])
    let store = LibraryStore()
    private let gate = Gate(limit: 6)
    private var toastDismissal: Task<Void, Never>?

    func load() async {
        let saved = await store.loadAll()
        // Links opened with the app (a nab:// URL, the shortcut) can arrive while the library is read; they are
        // newer, so they stay on top and their saved copies are skipped.
        let added = Set(entries.map(\.id))
        let restored = saved.filter { !added.contains($0.id) }
        entries += restored
        // An entry still fetching when the app quit is fetched again.
        for entry in restored where entry.phase == .fetching { fetch(entry.id) }
    }

    /// The shortcut: read the browser's front tab and start fetching it.
    func nabFrontTab() async {
        let registry = registry
        show(.init(tone: .working, title: "Reading the front tab…", detail: ""), hold: true)
        switch await BrowserBridge.frontTab(accept: { registry.match($0) != nil }) {
        case .success(let tab): add(tab.url, title: Self.cleanTitle(tab.title))
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

    func add(_ url: URL, title: String?, announce: Bool = true) {
        guard let match = registry.match(url) else {
            show(.init(tone: .failed, title: "Nab can't read this link yet", detail: url.host() ?? url.absoluteString))
            return
        }
        if let index = entries.firstIndex(where: { $0.id == match.entryID }) {
            var entry = entries.remove(at: index)
            entry.addedAt = .now
            entry.inTray = true
            entries.insert(entry, at: 0)
            persist(entry)
            if entry.phase == .failed { retry(entry.id) }
            if announce {
                show(
                    .init(
                        tone: .done, title: entry.title, detail: "Already in your tray", thumbnail: entry.thumbnailURL))
            }
            return
        }
        let entry = Entry(id: match.entryID, url: url, provisionalTitle: title)
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

    func remove(_ ids: Set<String>) {
        entries.removeAll { ids.contains($0.id) }
        let store = store
        Task {
            for id in ids {
                await store.delete(id)
                await store.deleteConversation(id)
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

    func copyTray() {
        let captures = trayCaptures
        guard !captures.isEmpty else { return }
        Pasteboard.copy(ContextPack.render(captures))
        show(
            .init(
                tone: .done, title: "Context copied",
                detail: "\(captures.count) video\(captures.count == 1 ? "" : "s") · paste into any AI"))
    }

    private func fetch(_ id: String) {
        guard let entry = entry(id), let provider = registry.match(entry.url)?.provider else { return }
        let url = entry.url
        let gate = gate
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

        let remaining = inFlight
        switch (entry.phase, remaining) {
        case (.failed, _):
            show(
                .init(
                    tone: .failed, title: entry.title, detail: entry.failure ?? "Failed", thumbnail: entry.thumbnailURL)
            )
        case (_, 0):
            show(.init(tone: .done, title: entry.title, detail: entry.metaLine, thumbnail: entry.thumbnailURL))
        default:
            show(
                .init(
                    tone: .working, title: entry.title, detail: "Done · \(remaining) more in flight",
                    thumbnail: entry.thumbnailURL), hold: true)
        }
    }

    private func persist(_ entry: Entry) {
        let store = store
        Task { await store.save(entry) }
    }

    // MARK: Toast

    private func show(_ next: Toast, hold: Bool = false) {
        var next = next
        next.pulse = (toast?.pulse ?? 0) + 1
        toast = next
        toastDismissal?.cancel()
        guard !hold else { return }
        toastDismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.tone == .failed ? 3.6 : 2.2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    func dismissToast() {
        toastDismissal?.cancel()
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
