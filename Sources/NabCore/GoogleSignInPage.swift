import Foundation

/// Tells whether a page in the sign-in window is Google's refusal to sign in inside an embedded browser.
/// The markers are an assumption from how Google words and addresses that page; they are checked against
/// the address first (stable) and the title second (localised, so only the English wording is known).
public enum GoogleSignInPage {
    public static func isBlocked(url: URL?, title: String?) -> Bool {
        if let url {
            let text = url.absoluteString.lowercased()
            if text.contains("/signin/rejected") || text.contains("disallowed_useragent") { return true }
        }
        let lowered = (title ?? "").lowercased()
        return lowered.contains("browser or app may not be secure") || lowered.contains("couldn't sign you in")
    }

    /// Cookies of these sites are what signing in leaves behind; Sign Out removes exactly them.
    public static func isSignInRecord(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["google.com", "youtube.com", "youtube-nocookie.com"].contains {
            lowered == $0 || lowered.hasSuffix("." + $0)
        }
    }
}
