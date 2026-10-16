import AppKit
import Carbon.HIToolbox
import NabCore
import SwiftUI
import WebKit

/// Nab's own small player: one floating panel with YouTube's IFrame Player API inside. YouTube's rules hold here:
/// nothing is drawn over the video, ads are not blocked, and the video area is never smaller than 200×200 px.
@MainActor
final class MiniPlayer: NSObject {
    static let shared = MiniPlayer()

    /// The video area is a fixed 16:9, 384×216 pt; the glass title strip sits above it, not on it.
    static let videoSize = NSSize(width: 384, height: 216)
    static let stripHeight: CGFloat = 34
    /// Google wants the Referer to name the app; this is the origin every load claims.
    static let baseURL = URL(string: "https://dev.tavsan.nab/")!
    static let probeEnabled = ProcessInfo.processInfo.environment["NAB_PLAYER_PROBE"] == "1"

    private static let embedErrors: Set<Int> = [2, 5, 100, 101, 150, 153]
    private static let allowedHosts = [
        "youtube.com", "youtube-nocookie.com", "google.com", "googlevideo.com", "ytimg.com", "gstatic.com", "ggpht.com",
    ]

    private var panel: PlayerPanel?
    private var web: WKWebView?
    private var state = PlayerState()
    private var videoID: String?
    private var ready = false
    private var readyTimeout: Task<Void, Never>?
    private var onEmbedFailure: ((String) -> Void)?

    /// True for the panel and anything it opens, so the Ask window does not treat a click there as leaving.
    func owns(_ window: NSWindow?) -> Bool { window != nil && window === panel }

    /// Shows `videoID` at `seconds`. `onEmbedFailure` runs once if YouTube refuses to embed it.
    func play(videoID id: String, title: String?, at seconds: TimeInterval, onEmbedFailure: @escaping (String) -> Void)
    {
        guard YouTubeID.isValid(id) else { return }
        let start = seconds.wholeSeconds
        self.onEmbedFailure = onEmbedFailure
        let panel = self.panel ?? makePanel()
        state.title = title ?? "YouTube"
        state.videoID = id
        if !panel.isVisible { place(panel) }
        panel.orderFrontRegardless()
        if videoID == id, ready, let web {
            web.evaluateJavaScript("player.seekTo(\(start), true); player.playVideo();")
        } else {
            load(id, start: start)
        }
    }

    func close() {
        readyTimeout?.cancel()
        web?.loadHTMLString("", baseURL: nil)
        videoID = nil
        ready = false
        panel?.orderOut(nil)
    }

    func togglePlayback() {
        web?.evaluateJavaScript("player.getPlayerState() === 1 ? player.pauseVideo() : player.playVideo();")
    }

    func openInBrowser() {
        if let videoID { PlaybackRouter.shared.openInBrowser(videoID: videoID) }
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
        if Self.probeEnabled { probe(start: start) }
    }

    private func failEmbed() {
        guard let id = videoID, let callback = onEmbedFailure else { return }
        onEmbedFailure = nil
        close()
        callback(id)
    }

    fileprivate func handle(_ body: Any) {
        guard let message = body as? [String: Any], let event = message["e"] as? String else { return }
        switch event {
        case "ready":
            ready = true
            readyTimeout?.cancel()
        case "error":
            if let code = message["c"] as? Int, Self.embedErrors.contains(code) { failEmbed() }
        default: break
        }
    }

    /// With `NAB_PLAYER_PROBE=1`: a few seconds after the load, logs where the player is against where it was sent.
    private func probe(start: Int) {
        Task { [weak self] in
            for delay in [3.0, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, let web = self.web else { return }
                let now = try? await web.evaluateJavaScript("player.getCurrentTime()")
                let line = "[player] target=\(start) current=\(now.map { "\($0)" } ?? "?") ready=\(self.ready)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
    }

    // MARK: Window

    private func makePanel() -> PlayerPanel {
        let config = WKWebViewConfiguration()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .nonPersistent()
        let proxy = ScriptProxy(owner: self)
        config.userContentController.add(proxy, name: "nab")
        let web = WKWebView(frame: NSRect(origin: .zero, size: Self.videoSize), configuration: config)
        web.navigationDelegate = proxy
        web.uiDelegate = proxy
        web.setValue(false, forKey: "drawsBackground")
        self.web = web

        let strip = NSHostingView(
            rootView: PlayerStrip(
                state: state, openInBrowser: { [weak self] in self?.openInBrowser() },
                close: { [weak self] in self?.close() }))
        let size = NSSize(width: Self.videoSize.width, height: Self.videoSize.height + Self.stripHeight)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = Radius.card
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.backgroundColor = NSColor.black.cgColor
        web.frame = NSRect(origin: .zero, size: Self.videoSize)
        strip.frame = NSRect(x: 0, y: Self.videoSize.height, width: size.width, height: Self.stripHeight)
        root.addSubview(web)
        root.addSubview(strip)

        let panel = PlayerPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = root
        panel.onClose = { [weak self] in self?.close() }
        panel.onToggle = { [weak self] in self?.togglePlayback() }
        self.panel = panel
        return panel
    }

    private func place(_ panel: PlayerPanel) {
        if panel.setFrameUsingName(PlayerPanel.autosaveName) { return }
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - Space.xl, y: visible.minY + Space.xl))
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
private final class PlayerState {
    var title = ""
    var videoID = ""
}

/// The glass strip above the video: title, open in the browser, close.
private struct PlayerStrip: View {
    let state: PlayerState
    let openInBrowser: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(state.title)
                .font(Typeface.meta)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(symbol: "arrow.up.right.square", help: "Open on YouTube", action: openInBrowser)
            IconButton(symbol: "xmark", help: "Close (Esc)", action: close)
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }
}

/// A floating, non-activating panel: the browser stays in front and the Ask window stays open while it is used.
private final class PlayerPanel: NSPanel {
    static let autosaveName = "dev.tavsan.nab.miniplayer"
    var onClose: () -> Void = {}
    var onToggle: () -> Void = {}

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        setFrameAutosaveName(Self.autosaveName)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Keys are taken before the web view sees them, so Space and Esc mean the same wherever the focus is.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = Int(event.keyCode)
            if flags.isEmpty, key == kVK_Escape { return onClose() }
            if flags.isEmpty, key == kVK_Space { return onToggle() }
            if flags == .command, key == kVK_ANSI_W { return onClose() }
        }
        super.sendEvent(event)
    }
}
