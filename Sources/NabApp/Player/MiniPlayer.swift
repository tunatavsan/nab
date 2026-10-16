import AppKit
import NabCore
import SwiftUI
import WebKit

/// Nab's player: one YouTube IFrame Player API page in one web view, which lives either embedded above a video's
/// page in the library window or in the pin, a floating panel. Pinning carries the same web view across, so playback
/// does not stop. YouTube's rules hold: nothing is drawn over the video, ads are not blocked, and the video area is
/// never smaller than 200×200 px.
@MainActor
@Observable
final class MiniPlayer: NSObject {
    static let shared = MiniPlayer()

    /// Google wants the Referer to name the app; this is the origin every load claims.
    @ObservationIgnored static let baseURL = URL(string: "https://dev.tavsan.nab/")!
    @ObservationIgnored static let probeEnabled = ProcessInfo.processInfo.environment["NAB_PLAYER_PROBE"] == "1"

    @ObservationIgnored private static let embedErrors: Set<Int> = [2, 5, 100, 101, 150, 153]
    @ObservationIgnored private static let allowedHosts = [
        "youtube.com", "youtube-nocookie.com", "google.com", "googlevideo.com", "ytimg.com", "gstatic.com", "ggpht.com",
    ]

    /// The video id the library page of that video shows the embedded player for.
    private(set) var embeddedVideoID: String?
    private(set) var isPinned = false

    @ObservationIgnored private var pin: PinPanel?
    @ObservationIgnored private var web: WKWebView?
    @ObservationIgnored private weak var embeddedHost: NSView?
    @ObservationIgnored let state = PlayerState()
    @ObservationIgnored private(set) var videoID: String?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var readyTimeout: Task<Void, Never>?
    @ObservationIgnored private var onEmbedFailure: ((String) -> Void)?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var target = 0

    /// True for the pin and the sign-in window, so the Ask window does not treat a click there as leaving.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === pin || YouTubeSignIn.shared.owns(window) }

    // MARK: Playing

    /// Plays in the library window: the page of that video shows the player above it.
    func playEmbedded(videoID id: String, at seconds: TimeInterval, onEmbedFailure: @escaping (String) -> Void) {
        guard YouTubeID.isValid(id) else { return }
        self.onEmbedFailure = onEmbedFailure
        embeddedVideoID = id
        start(id, seconds.wholeSeconds)
    }

    /// Plays in the pin, which is already open.
    func playPinned(videoID id: String, at seconds: TimeInterval, onEmbedFailure: @escaping (String) -> Void) {
        guard YouTubeID.isValid(id), isPinned else { return }
        self.onEmbedFailure = onEmbedFailure
        state.title = PlaybackRouter.shared.title("youtube:\(id)") ?? "YouTube"
        start(id, seconds.wholeSeconds)
    }

    private func start(_ id: String, _ seconds: Int) {
        target = seconds
        ensureWeb()
        if videoID == id, ready, let web {
            web.evaluateJavaScript("player.seekTo(\(seconds), true); player.playVideo();")
        } else {
            load(id, start: seconds)
        }
    }

    // MARK: Pin

    /// The pin button: the embedded player grows out of its place into the floating panel, still playing.
    func pinEmbedded() {
        guard let id = videoID, !isPinned, let web else { return }
        let from = embeddedHost.flatMap { host in
            host.window.map { $0.convertToScreen(host.convert(host.bounds, to: nil)) }
        }
        let panel = pin ?? makePin()
        state.title = PlaybackRouter.shared.title("youtube:\(id)") ?? "YouTube"
        panel.root.attach(web)
        isPinned = true
        embeddedVideoID = nil
        panel.open(from: from)
    }

    /// Unpin: the panel goes and the player returns to its video's page in the library window, playing on.
    func unpin() {
        guard isPinned, let id = videoID else { return }
        Task {
            let now = try? await web?.evaluateJavaScript("player.getCurrentTime()")
            isPinned = false
            pin?.dismiss()
            embeddedVideoID = id
            PlaybackRouter.shared.showInLibrary("youtube:\(id)", (now as? Double) ?? 0)
        }
    }

    /// Closes the pin and stops playback.
    func closePin() {
        endPlayback()
        pin?.dismiss()
        isPinned = false
    }

    private func endPlayback() {
        readyTimeout?.cancel()
        web?.loadHTMLString("", baseURL: nil)
        videoID = nil
        ready = false
        embeddedVideoID = nil
    }

    func togglePlayback() {
        web?.evaluateJavaScript("player.getPlayerState() === 1 ? player.pauseVideo() : player.playVideo();")
    }

    func openInBrowser() {
        if let videoID { PlaybackRouter.shared.openInBrowser(videoID: videoID) }
    }

    func signIn() {
        YouTubeSignIn.shared.currentVideoID = { [weak self] in self?.videoID }
        YouTubeSignIn.shared.show()
    }

    func signOut() {
        Task {
            await YouTubeSignIn.shared.signOut()
            // Reload so the player forgets the account at once.
            if let id = videoID { load(id, start: 0) }
        }
    }

    // MARK: Embedded host

    fileprivate func attachEmbedded(_ host: NSView) {
        embeddedHost = host
        ensureWeb()
        if let web, !isPinned {
            host.addSubview(web)
            web.frame = host.bounds
        }
    }

    fileprivate func detachEmbedded(_ host: NSView) {
        guard let web, web.superview === host else { return }
        web.evaluateJavaScript("player && player.pauseVideo && player.pauseVideo();")
        web.removeFromSuperview()
    }

    // MARK: Loading

    private func load(_ id: String, start: Int) {
        videoID = id
        ready = false
        // `id` passed `YouTubeID.isValid` and `start` is an Int, so nothing else can reach the page.
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <meta name="referrer" content="strict-origin-when-cross-origin">
            <style>html,body{margin:0;height:100%;background:#000;overflow:hidden}#p{width:100%;height:100%}</style>
            </head><body><div id="p"></div>
            <script src="https://www.youtube.com/iframe_api"></script>
            <script>
            var player;
            function post(m){window.webkit.messageHandlers.nab.postMessage(m)}
            function onYouTubeIframeAPIReady(){
              player=new YT.Player('p',{videoId:'\(id)',width:'100%',height:'100%',
                playerVars:{enablejsapi:1,origin:'https://dev.tavsan.nab',playsinline:1,rel:0,autoplay:1,start:\(start)},
                events:{onReady:function(){post({e:'ready'})},
                  onError:function(x){post({e:'error',c:x.data})},
                  onStateChange:function(x){post({e:'state',s:x.data})}}});
            }
            </script></body></html>
            """
        web?.loadHTMLString(html, baseURL: Self.baseURL)
        readyTimeout?.cancel()
        readyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, !self.ready, self.videoID == id else { return }
            self.failEmbed()
        }
    }

    private func failEmbed() {
        if Self.probeEnabled { log("embed failure") }
        guard let id = videoID, let callback = onEmbedFailure else { return }
        onEmbedFailure = nil
        if isPinned { closePin() } else { endPlayback() }
        callback(id)
    }

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["e"] as? String else { return }
        switch event {
        case "ready":
            ready = true
            readyTimeout?.cancel()
        case "error":
            if Self.probeEnabled { log("error \(message["c"] ?? "?")") }
            if let code = message["c"] as? Int, Self.embedErrors.contains(code) { failEmbed() }
        default: break
        }
    }

    // MARK: Probe

    private func log(_ text: String) { FileHandle.standardError.write(Data("[player] \(text)\n".utf8)) }

    /// With `NAB_PLAYER_PROBE=1`: every 2 s logs where the player is against where it was last sent, and where.
    private func startProbe() {
        guard Self.probeEnabled, probeTask == nil else { return }
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, let web = self.web, self.videoID != nil else { continue }
                let now = try? await web.evaluateJavaScript("player.getCurrentTime()")
                let frame = self.isPinned ? (self.pin.map { NSStringFromRect($0.frame) } ?? "?") : "-"
                self.log(
                    "mode=\(self.isPinned ? "pin" : "embedded") video=\(self.videoID ?? "-") target=\(self.target) "
                        + "current=\(now.map { "\($0)" } ?? "?") panel=\(frame)")
            }
        }
    }

    // MARK: Web view

    private func ensureWeb() {
        guard web == nil else { return }
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        // The persistent store: a YouTube sign-in made in the sign-in window lasts, and Sign Out clears it.
        config.websiteDataStore = .default()
        let proxy = ScriptProxy(owner: self)
        config.userContentController.add(proxy, name: "nab")
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 384, height: 216), configuration: config)
        web.navigationDelegate = proxy
        web.uiDelegate = proxy
        web.setValue(false, forKey: "drawsBackground")
        self.web = web
        startProbe()
    }

    private func makePin() -> PinPanel {
        let panel = PinPanel(state: state)
        panel.onToggle = { [weak self] in self?.togglePlayback() }
        panel.root.actions = PinActions(
            close: { [weak self] in self?.closePin() }, unpin: { [weak self] in self?.unpin() },
            openInBrowser: { [weak self] in self?.openInBrowser() }, signIn: { [weak self] in self?.signIn() },
            signOut: { [weak self] in self?.signOut() })
        pin = panel
        return panel
    }

    // MARK: Navigation policy

    fileprivate func allows(_ url: URL) -> Bool {
        if url.scheme == "about" { return true }
        guard url.scheme == "https", let host = url.host()?.lowercased() else { return false }
        if host == Self.baseURL.host() { return true }
        return Self.allowedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Keeps the page's messages and navigation decisions out of `MiniPlayer`'s own interface. A page can only report
/// state and errors; nothing it sends is a command.
@MainActor
private final class ScriptProxy: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private weak var owner: MiniPlayer?
    init(owner: MiniPlayer) { self.owner = owner }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.handle(message.body)
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // The rule applies to the main frame, to link clicks and to new windows; the player's own subframes,
        // ads included, load freely.
        let isMain = action.targetFrame?.isMainFrame ?? true
        let governed = isMain || action.navigationType == .linkActivated
        guard governed, let url = action.request.url else { return decisionHandler(.allow) }
        // A new window has nowhere to open inside the panel, so it goes to the browser like any foreign address.
        if action.targetFrame != nil, owner?.allows(url) ?? false { return decisionHandler(.allow) }
        // Anything the player wants to show elsewhere goes to the browser; only http(s) is ever opened.
        if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = action.request.url, url.scheme == "https" { NSWorkspace.shared.open(url) }
        return nil
    }
}

@MainActor
@Observable
final class PlayerState {
    var title = ""
}

// MARK: Embedded in the library window

/// The player above a video's page: 16:9 at column width, with the pin button in a row above it (nothing is drawn
/// over the video itself).
struct EmbeddedPlayer: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: Space.xs) {
            IconButton(symbol: "pin", help: "Pin the player: it floats above your other windows") {
                MiniPlayer.shared.pinEmbedded()
            }
            EmbedHostView()
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Radius.thumb, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).strokeBorder(Palette.line))
        }
    }
}

private struct EmbedHostView: NSViewRepresentable {
    func makeNSView(context: Context) -> EmbedHost {
        let host = EmbedHost()
        MiniPlayer.shared.attachEmbedded(host)
        return host
    }

    func updateNSView(_ host: EmbedHost, context: Context) {}

    static func dismantleNSView(_ host: EmbedHost, coordinator: ()) {
        MiniPlayer.shared.detachEmbedded(host)
    }
}

private final class EmbedHost: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        for view in subviews { view.frame = bounds }
    }
}
