import Foundation

/// The PATH a CLI provider is searched for and run with. An app opened from the Dock, Finder or Spotlight starts
/// with launchd's PATH (`/usr/bin:/bin:/usr/sbin:/sbin`), and the login shell it runs the command in does not
/// read `~/.zshrc`, where the installers of `claude` and others add `~/.local/bin`.
public enum CLIPath {
    /// Where the CLIs' installers put them, in the order they are tried after the user's own PATH.
    public static func extraDirectories(home: String = NSHomeDirectory()) -> [String] {
        ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    }

    /// `path` with the usual install folders appended. The order of `path` is kept and nothing is added twice.
    public static func augmented(_ path: String?, home: String = NSHomeDirectory()) -> String {
        var result = (path ?? "").split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        for directory in extraDirectories(home: home) where !result.contains(directory) {
            result.append(directory)
        }
        return result.joined(separator: ":")
    }

    /// The process environment with the augmented PATH.
    public static func environment(
        _ base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        environment["PATH"] = augmented(base["PATH"])
        return environment
    }
}
