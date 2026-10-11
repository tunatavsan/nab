import AppKit

struct FrontTab: Sendable {
    let url: URL
    let title: String?
}

/// Reads the active tab of a browser over Apple Events. Chromium browsers share Chrome's scripting
/// dictionary; Safari has its own. Firefox-based browsers expose none, so they are not listed.
enum BrowserBridge {
    private enum Family { case chromium, safari }

    private static let browsers: [(id: String, family: Family)] = [
        ("net.imput.helium", .chromium),
        ("com.google.Chrome", .chromium),
        ("com.google.Chrome.canary", .chromium),
        ("company.thebrowser.Browser", .chromium),
        ("company.thebrowser.dia", .chromium),
        ("com.brave.Browser", .chromium),
        ("com.microsoft.edgemac", .chromium),
        ("com.vivaldi.Vivaldi", .chromium),
        ("org.chromium.Chromium", .chromium),
        ("ai.perplexity.comet", .chromium),
        ("com.operasoftware.Opera", .chromium),
        ("com.apple.Safari", .safari),
        ("com.apple.SafariTechnologyPreview", .safari),
    ]

    /// One serial queue: NSAppleScript is not safe to run concurrently, and keeping it off the main
    /// thread keeps the capture toast animating while the browser answers.
    private static let queue = DispatchQueue(label: "dev.tavsan.nab.applescript", qos: .userInitiated)

    /// The active tab of the browser in front; if the front app is not a browser, the first running
    /// browser whose active tab `accept`s.
    @MainActor
    static func frontTab(accept: @escaping @Sendable (URL) -> Bool) async -> Result<FrontTab, NabBridgeError> {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let candidates: [(id: String, family: Family)]
        if let front, let browser = browsers.first(where: { $0.id == front }) {
            candidates = [browser]
        } else {
            candidates = browsers.filter { running.contains($0.id) }
        }
        guard !candidates.isEmpty else { return .failure(.noBrowser) }

        var lastError: NabBridgeError = .noLink
        for candidate in candidates {
            switch await read(candidate.id, candidate.family) {
            case .success(let tab) where accept(tab.url): return .success(tab)
            case .success: lastError = .noLink
            case .failure(let error): lastError = error
            }
        }
        return .failure(lastError)
    }

    private static func read(_ bundleID: String, _ family: Family) async -> Result<FrontTab, NabBridgeError> {
        let (tab, nameKey) = family == .safari ? ("current tab", "name") : ("active tab", "title")
        let source = """
            with timeout of 4 seconds
                tell application id "\(bundleID)"
                    if (count of windows) is 0 then return ""
                    return (URL of \(tab) of front window) & linefeed & (\(nameKey) of \(tab) of front window)
                end tell
            end timeout
            """
        let name =
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID

        return await withCheckedContinuation { continuation in
            queue.async {
                var error: NSDictionary?
                let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
                if let error {
                    let code = error[NSAppleScript.errorNumber] as? Int ?? 0
                    continuation.resume(returning: .failure(code == -1743 ? .notAllowed(name) : .scriptFailed(name)))
                    return
                }
                let lines = (output ?? "").split(separator: "\n", maxSplits: 1).map(String.init)
                guard let first = lines.first, let url = URL(string: first) else {
                    continuation.resume(returning: .failure(.noLink))
                    return
                }
                continuation.resume(returning: .success(FrontTab(url: url, title: lines.count > 1 ? lines[1] : nil)))
            }
        }
    }
}

enum NabBridgeError: Error, Sendable {
    case noBrowser, noLink
    case notAllowed(String)
    case scriptFailed(String)

    var message: String {
        switch self {
        case .noBrowser: "No supported browser is open."
        case .noLink: "The front tab isn't a YouTube video."
        case .notAllowed(let browser): "Allow Nab in Settings › Privacy › Automation › \(browser)."
        case .scriptFailed(let browser): "\(browser) did not answer."
        }
    }
}
