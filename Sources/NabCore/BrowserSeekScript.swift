import Foundation

public enum BrowserFamily: Sendable { case chromium, safari }

/// The AppleScript Nab runs in a browser that has the video open. Pure, so it can be tested: only a validated id,
/// a whole number of seconds and a bundle id from Nab's own list ever reach the source text.
public enum BrowserSeekScript {
    public enum Action: Equatable, Sendable {
        /// Set the playing position with the page's own script.
        case script(seconds: Int)
        /// Change the tab's address to the moment.
        case address(seconds: Int)
        /// Only bring the tab forward.
        case raise
    }

    /// Printed by the script; the runner reads it back.
    public enum Outcome: String, Sendable {
        case done
        case noTab = "no-tab"
        case scriptDenied = "script-denied"
    }

    public static func source(bundleID: String, family: BrowserFamily, videoID: String, action: Action) -> String? {
        guard YouTubeID.isValid(videoID), !bundleID.isEmpty,
            bundleID.utf8.allSatisfy({
                ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2E || $0 == 0x2D
            })
        else { return nil }
        let address = "https://www.youtube.com/watch?v=\(videoID)"
        let act: String
        switch action {
        case .raise: act = ""
        case .address(let seconds): act = "set URL of t to \"\(address)&t=\(clamp(seconds))s\"\n"
        case .script(let seconds):
            let js = "var v=document.querySelector('video');if(v){v.currentTime=\(clamp(seconds));v.play();}"
            let run = family == .safari ? "do JavaScript \"\(js)\" in t" : "execute t javascript \"\(js)\""
            act = "try\n\(run)\non error\nreturn \"\(Outcome.scriptDenied.rawValue)\"\nend try\n"
        }
        let front =
            family == .safari
            ? "set current tab of w to t\nset index of w to 1"
            : "set active tab index of w to i\nset index of w to 1"
        return """
            with timeout of 6 seconds
            tell application id "\(bundleID)"
            repeat with w in windows
            set i to 0
            repeat with t in tabs of w
            set i to i + 1
            set u to URL of t
            if (u contains "youtu.be/\(videoID)") or ((u contains "youtube.com/watch") and (u contains "v=\(videoID)")) then
            \(act)\(front)
            activate
            return "\(Outcome.done.rawValue)"
            end if
            end repeat
            end repeat
            return "\(Outcome.noTab.rawValue)"
            end tell
            end timeout
            """
    }

    private static func clamp(_ seconds: Int) -> Int { min(max(seconds, 0), 86_400) }
}
