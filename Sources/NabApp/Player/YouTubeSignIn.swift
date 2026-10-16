import AppKit
import NabCore
import SwiftUI
import WebKit

/// Signing in to YouTube for the mini player: a small separate window on the persistent web data store that the
/// player also uses. Google may refuse to sign in inside an embedded browser; when it does, the window says so
/// and offers the browser instead. Nothing here promises what an account changes about the video.
@MainActor
final class YouTubeSignIn: NSObject {
    static let shared = YouTubeSignIn()
    private static let address = URL(
        string: "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fwww.youtube.com%2F")!

    private var window: NSWindow?
    private var web: WKWebView?
    private let state = SignInState()
    /// Called with the video that was playing when "Play in Browser" is chosen.
    var currentVideoID: () -> String? = { nil }

    func owns(_ other: NSWindow?) -> Bool { other != nil && other === window }

    func show() {
        state.blocked = false
        if window == nil { build() }
        web?.load(URLRequest(url: Self.address))
        window?.makeKeyAndOrderFront(nil)
    }

    /// Removes the Google and YouTube cookies and the like from the store; the player reloads signed out.
    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records = await store.dataRecords(ofTypes: types)
        await store.removeData(ofTypes: types, for: records.filter { GoogleSignInPage.isSignInRecord($0.displayName) })
    }

    private func build() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = self
        self.web = web
        let notice = NSHostingView(
            rootView: SignInNotice(
                state: state,
                playInBrowser: { [weak self] in
                    if let id = self?.currentVideoID() { PlaybackRouter.shared.openInBrowser(videoID: id) }
                    self?.window?.close()
                }))
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 640))
        for view in [web, notice] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        notice.isHidden = true
        state.onBlockedChange = { [weak notice] blocked in notice?.isHidden = !blocked }
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: true)
        window.title = "Sign in to YouTube"
        window.contentView = root
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }
}

extension YouTubeSignIn: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        state.blocked = GoogleSignInPage.isBlocked(url: webView.url, title: webView.title)
    }
}

@MainActor
@Observable
private final class SignInState {
    var blocked = false { didSet { onBlockedChange?(blocked) } }
    @ObservationIgnored var onBlockedChange: ((Bool) -> Void)?
}

private struct SignInNotice: View {
    let state: SignInState
    let playInBrowser: () -> Void

    var body: some View {
        VStack(spacing: Space.m) {
            Text("Google won't sign in here")
                .font(Typeface.heading)
                .foregroundStyle(Palette.ink)
            Text(
                "Google doesn't allow signing in inside some apps' built-in browsers. Videos still play in Nab's player, or you can play them in your browser, where you may already be signed in."
            )
            .font(Typeface.body)
            .foregroundStyle(Palette.inkSecondary)
            .multilineTextAlignment(.center)
            NabButton("Play in Browser", kind: .primary, action: playInBrowser)
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.window)
    }
}
