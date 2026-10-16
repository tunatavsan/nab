import AppKit
import NabCore
import SwiftUI

/// The one way a timecode becomes playback. A click names an entry and a moment; the router validates the video
/// id, asks `PlaybackPlan` where to go and tries those places in order.
@MainActor
final class PlaybackRouter {
    static let shared = PlaybackRouter()
    static let defaultsKey = "player.target"

    /// Title lookup for the player strip; the app delegate sets it.
    var title: (String) -> String? = { _ in nil }
    private var scriptHintShown = false

    private var setting: PlaybackPlan.Setting {
        PlaybackPlan.Setting(stored: UserDefaults.standard.string(forKey: Self.defaultsKey))
    }

    func play(entryID: String, at seconds: TimeInterval) {
        guard let id = YouTubeID.id(fromEntryID: entryID) else { return }
        attempt(entryID: entryID, id: id, seconds: seconds.wholeSeconds, embedFailed: false, tab: nil, script: nil)
    }

    /// Opens the whole video in the browser; a tab that already has it is brought forward instead.
    func openInBrowser(entryID: String) {
        guard let id = YouTubeID.id(fromEntryID: entryID) else { return }
        openInBrowser(videoID: id)
    }

    func openInBrowser(videoID id: String) {
        guard YouTubeID.isValid(id) else { return }
        Task {
            if await BrowserSeek.run(videoID: id, action: .raise) != .done { Self.openNewTab(id, seconds: nil) }
        }
    }

    private func attempt(entryID: String, id: String, seconds: Int, embedFailed: Bool, tab: Bool?, script: Bool?) {
        let targets = PlaybackPlan.targets(setting: setting, embedFailed: embedFailed, tabMatch: tab, jsAllowed: script)
        guard let target = targets.first else { return }
        func next(embedFailed: Bool = embedFailed, tab: Bool? = tab, script: Bool? = script) {
            attempt(entryID: entryID, id: id, seconds: seconds, embedFailed: embedFailed, tab: tab, script: script)
        }
        switch target {
        case .mini:
            MiniPlayer.shared.play(videoID: id, title: title(entryID), at: TimeInterval(seconds)) { [weak self] _ in
                PlayerNotice.show("This video can't play inside Nab — opened in your browser.")
                self?.attempt(entryID: entryID, id: id, seconds: seconds, embedFailed: true, tab: nil, script: nil)
            }
        case .tabScript:
            Task {
                switch await BrowserSeek.run(videoID: id, action: .script(seconds: seconds)) {
                case .done: break
                case .scriptDenied: next(tab: true, script: false)
                case .noTab, .failed: next(tab: false)
                }
            }
        case .tabAddress:
            Task {
                switch await BrowserSeek.run(videoID: id, action: .address(seconds: seconds)) {
                case .done: if script == false { hintAboutScripts() }
                case .noTab, .failed, .scriptDenied: next(tab: false)
                }
            }
        case .newTab:
            Self.openNewTab(id, seconds: seconds)
        }
    }

    /// Said once per launch, when the browser refused the position script and the tab's address was changed instead.
    private func hintAboutScripts() {
        guard !scriptHintShown else { return }
        scriptHintShown = true
        PlayerNotice.show(
            "Your browser blocked page scripts, so the tab reloaded at the moment. Allow JavaScript from Apple Events to seek in place: Safari Settings › Developer, Chrome View › Developer."
        )
    }

    private static func openNewTab(_ id: String, seconds: Int?) {
        var parts = URLComponents(string: "https://www.youtube.com/watch")
        parts?.queryItems = [.init(name: "v", value: id)]
        if let seconds { parts?.queryItems?.append(.init(name: "t", value: "\(seconds)s")) }
        if let url = parts?.url { NSWorkspace.shared.open(url) }
    }
}

/// A short line in a glass capsule near the top of the screen; used where the player falls back to the browser.
@MainActor
enum PlayerNotice {
    private static var panel: FloatingPanel?
    private static var dismissal: Task<Void, Never>?

    static func show(_ text: String) {
        dismissal?.cancel()
        panel?.orderOut(nil)
        let width: CGFloat = 420
        let panel = FloatingPanel(size: NSSize(width: width, height: 56), cornerRadius: Radius.card) {
            Text(text)
                .font(Typeface.meta)
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.card, style: .continuous))
        }
        self.panel = panel
        panel.placeTopCenter(offset: 24)
        panel.present()
        dismissal = Task {
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            panel.dismiss()
        }
    }
}

/// Links in an AI answer that are not timecodes. The answer is model output and can repeat text from a transcript,
/// so only web addresses go anywhere (to the browser); `file:`, `shortcuts:`, `nab:` and the like are ignored.
@MainActor
enum AnswerLinks {
    static func handle(_ url: URL) -> OpenURLAction.Result {
        if url.scheme == "https" || url.scheme == "http" { NSWorkspace.shared.open(url) }
        return .handled
    }
}
