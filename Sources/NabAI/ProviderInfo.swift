import Foundation

extension ProviderKind {
    /// The name on the settings page's provider list.
    public var shortTitle: String {
        switch self {
        case .claudeCLI: "Claude Code"
        case .codexCLI: "Codex"
        case .anthropic: "Anthropic API"
        case .openAI: "OpenAI API"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Custom server"
        }
    }

    /// One line under the name.
    public var blurb: String {
        switch self {
        case .claudeCLI: "Uses your Claude subscription"
        case .codexCLI: "Uses your ChatGPT plan"
        case .anthropic, .openAI: "Pay per use with an API key"
        case .openRouter: "One key, many models"
        case .ollama, .lmStudio: "Runs on this Mac"
        case .custom: "Any OpenAI-compatible server"
        }
    }

    /// Whether the provider is a server on this Mac that can be probed.
    public var isLocalServer: Bool { self == .ollama || self == .lmStudio }

    /// Listed first.
    public static let common: [ProviderKind] = [.claudeCLI, .codexCLI, .anthropic, .openAI, .ollama]
    /// Listed under "More providers".
    public static let more: [ProviderKind] = [.openRouter, .lmStudio, .custom]
}

/// What the provider list says on the right of each row.
public enum ProviderStatus: Equatable, Sendable {
    case checking, ready, notFound, addKey, keySaved, running, notRunning
    case address(String)

    public var label: String {
        switch self {
        case .checking: "Checking…"
        case .ready: "Ready"
        case .notFound: "Not found"
        case .addKey: "Add key"
        case .keySaved: "Key saved"
        case .running: "Running"
        case .notRunning: "Not running"
        case .address(let url): url.isEmpty ? "Add address" : url
        }
    }

    /// Whether the provider can be used as it stands.
    public var isPositive: Bool { self == .ready || self == .keySaved || self == .running }

    public static func cli(found: Bool) -> ProviderStatus { found ? .ready : .notFound }
    public static func key(saved: Bool) -> ProviderStatus { saved ? .keySaved : .addKey }
    public static func server(running: Bool) -> ProviderStatus { running ? .running : .notRunning }
}

/// Finds out whether a provider can be reached, the way the app would run it.
public enum ProviderProbe {
    /// The program a CLI command starts: its first word that is not a `NAME=value` assignment.
    public static func executable(in command: String) -> String? {
        for word in command.split(whereSeparator: \.isWhitespace) {
            if word.contains("=") && !word.hasPrefix("/") && !word.hasPrefix(".") { continue }
            let name = String(word)
            let allowed = CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-+~")
            return name.unicodeScalars.allSatisfy(allowed.contains) ? name : nil
        }
        return nil
    }

    /// The model list endpoint of a server, used to see whether it is up.
    public static func modelsURL(baseURL: String) -> URL? {
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/models"), ["http", "https"].contains(url.scheme?.lowercased()),
            url.host() != nil
        else { return nil }
        return url
    }

    /// Looks the program up in the login shell, which is where the app runs it, so a CLI that only
    /// the terminal's PATH knows reads as found exactly when the app can start it.
    public static func cliFound(command: String, timeout: Duration = .seconds(8)) async -> Bool {
        guard let name = executable(in: command) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name) >/dev/null 2>&1"]
        process.environment = CLIPath.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(returning: false)
                return
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                if process.isRunning { process.terminate() }
            }
        }
    }

    /// True when the server answers its models endpoint at all within the timeout.
    public static func serverRunning(baseURL: String, timeout: TimeInterval = 1.5) async -> Bool {
        guard let url = modelsURL(baseURL: baseURL) else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        guard let (_, response) = try? await session.data(from: url) else { return false }
        return response is HTTPURLResponse
    }
}
