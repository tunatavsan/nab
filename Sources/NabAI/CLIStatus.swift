import Foundation

/// Where a CLI provider stands, for the setup guide. Nothing here keeps or shows an account name or e-mail:
/// only the state, the version and the sign-in method are read from the commands' output.
public enum CLIState: Equatable, Sendable {
    case checking, notInstalled, signedOut
    case ready(version: String?, method: String?)
}

public enum CLIStatus {
    /// The sign-in method in words, from `claude auth status`'s `authMethod`; nil when it says nothing usable.
    public static func methodLabel(authMethod: String?) -> String? {
        let value = (authMethod ?? "").lowercased()
        if value.isEmpty { return nil }
        if value.contains("claude") { return "Claude subscription" }
        if value.contains("api") || value.contains("key") || value.contains("token") { return "API key" }
        return nil
    }

    /// `claude auth status`: exit 1 means nobody is signed in; otherwise the JSON says. Only `loggedIn` and
    /// `authMethod` are read.
    public static func claudeAuth(exit: Int32, output: String) -> (signedIn: Bool, method: String?) {
        guard exit == 0 else { return (false, nil) }
        let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        guard let json else { return (true, nil) }
        if let loggedIn = json["loggedIn"] as? Bool, !loggedIn { return (false, nil) }
        return (true, methodLabel(authMethod: json["authMethod"] as? String))
    }

    /// `codex login status`: exit 0 means signed in. Its text may name the account, so it is never read.
    public static func codexAuth(exit: Int32) -> Bool { exit == 0 }

    /// The first dotted number in `--version` output ("2.1.301 (Claude Code)", "codex-cli 0.5.0").
    public static func version(from output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "vV(),")) }
            .first { word in
                let parts = word.split(separator: ".", omittingEmptySubsequences: false)
                return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            }
    }

    /// Install commands as the vendors publish them; Nab shows them for copying and never runs them.
    public static func installCommands(for kind: ProviderKind) -> [String] {
        switch kind {
        case .claudeCLI: ["curl -fsSL https://claude.ai/install.sh | bash"]
        case .codexCLI: ["npm i -g @openai/codex", "brew install --cask codex"]
        default: []
        }
    }

    public static func docsURL(for kind: ProviderKind) -> URL? {
        switch kind {
        case .claudeCLI: URL(string: "https://docs.claude.com/en/docs/claude-code/setup")
        case .codexCLI: URL(string: "https://developers.openai.com/codex/cli")
        default: nil
        }
    }

    /// What to type in a terminal to sign in.
    public static func loginSteps(for kind: ProviderKind) -> (text: String, copy: String)? {
        switch kind {
        case .claudeCLI: ("Run claude in a terminal, then type /login.", "claude")
        case .codexCLI: ("Run this in a terminal.", "codex login")
        default: nil
        }
    }

    private static func program(for kind: ProviderKind) -> String? {
        switch kind {
        case .claudeCLI: "claude"
        case .codexCLI: "codex"
        default: nil
        }
    }

    /// Looks the CLI up in the login shell (with the install folders on PATH), reads its version and asks it
    /// whether anyone is signed in. Each command gets `timeout`.
    public static func check(_ kind: ProviderKind, timeout: Duration = .seconds(8)) async -> CLIState {
        guard let name = program(for: kind) else { return .notInstalled }
        guard await run("command -v \(name) >/dev/null 2>&1", timeout: timeout)?.exit == 0 else {
            return .notInstalled
        }
        let found = await run("\(name) --version", timeout: timeout).flatMap { Self.version(from: $0.output) }
        if kind == .claudeCLI {
            guard let result = await run("claude auth status", timeout: timeout) else {
                return .ready(version: found, method: nil)
            }
            let auth = claudeAuth(exit: result.exit, output: result.output)
            return auth.signedIn ? .ready(version: found, method: auth.method) : .signedOut
        }
        guard let result = await run("codex login status", timeout: timeout) else {
            return .ready(version: found, method: nil)
        }
        return codexAuth(exit: result.exit) ? .ready(version: found, method: nil) : .signedOut
    }

    /// Runs `command` in the login shell; nil when it did not finish in time.
    private static func run(_ command: String, timeout: Duration) async -> (exit: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.environment = CLIPath.environment()
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let exit = AsyncStream<Int32> { continuation in
            process.terminationHandler = {
                continuation.yield($0.terminationStatus)
                continuation.finish()
            }
        }
        do { try process.run() } catch { return nil }
        let timer = Task.detached {
            try? await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        let data = await Task.detached { out.fileHandleForReading.readDataToEndOfFile() }.value
        var status: Int32?
        for await code in exit { status = code }
        timer.cancel()
        guard let status, !(Task.isCancelled), process.terminationReason == .exit else { return nil }
        return (status, String(decoding: data, as: UTF8.self))
    }
}
