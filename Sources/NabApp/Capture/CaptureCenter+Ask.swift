import NabCore

extension CaptureCenter {
    /// The ask shortcut: reads the browser's front tab and, when Nab reads that kind of link, nabs it like the nab
    /// shortcut does (session, library and rack) but without copying anything, and returns its entry id. Nil when
    /// there is no browser or the tab is not something Nab reads; the window then asks about the session instead.
    func nabFrontTabForAsk() async -> String? {
        let registry = registry
        show(.init(tone: .working, title: "Reading the front tab…", detail: ""), hold: true)
        switch await BrowserBridge.frontTab(accept: { registry.supports($0) }) {
        case .success(let tab):
            // A short link names its item only after one request.
            guard let url = try? await registry.expand(tab.url), let match = registry.match(url) else {
                dismissToast()
                return nil
            }
            add(url, title: Self.cleanTitle(tab.title))
            return match.entryID
        case .failure(let error):
            switch error {
            case .notAllowed, .waitingForPermission:
                show(.init(tone: .failed, title: "Nothing to nab", detail: error.message))
            default: dismissToast()
            }
            return nil
        }
    }

    /// Whether the record behind `id` is a photo or clip rather than a transcript, known before its capture arrives.
    func isMedia(_ id: String) -> Bool {
        guard let entry = entry(id) else { return false }
        return entry.capture?.isMedia ?? (entry.source != .youtube)
    }
}
