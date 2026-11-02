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
                show(.init(tone: .failed, title: "Nothing to nab", detail: "Nab couldn't open this short link."))
                return nil
            }
            add(url, title: Self.cleanTitle(tab.title))
            return match.entryID
        case .failure(let error):
            switch error {
            case .notAllowed, .waitingForPermission, .scriptFailed:
                show(.init(tone: .failed, title: "Nothing to nab", detail: error.message))
            default: dismissToast()
            }
            return nil
        }
    }
}
