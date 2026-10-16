import AppKit
import NabCore

/// Moves an already open YouTube tab to a moment, on BrowserBridge's serial AppleScript queue. It only reads tab
/// addresses and, in the tab whose address holds the video's id, sets the playing position (a number) or the
/// address. Nothing here runs unless the user chose the browser as the target or a video would not embed.
enum BrowserSeek {
    enum Outcome: Sendable { case done, noTab, scriptDenied, failed }

    /// Runs `action` in every running supported browser, stopping at the first tab that matches.
    static func run(videoID: String, action: BrowserSeekScript.Action) async -> Outcome {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        var outcome = Outcome.noTab
        for browser in BrowserBridge.browsers where running.contains(browser.id) {
            guard
                let source = BrowserSeekScript.source(
                    bundleID: browser.id, family: browser.family, videoID: videoID, action: action)
            else { return .failed }
            let answer = await execute(source)
            switch answer {
            case BrowserSeekScript.Outcome.done.rawValue: return .done
            case BrowserSeekScript.Outcome.scriptDenied.rawValue: return .scriptDenied
            case BrowserSeekScript.Outcome.noTab.rawValue: continue
            default: outcome = .failed
            }
        }
        return outcome
    }

    private static func execute(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            BrowserBridge.queue.async {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
                continuation.resume(returning: error == nil ? output : nil)
            }
        }
    }
}
