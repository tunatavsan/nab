import Foundation
import NabCore
import Synchronization

/// Sends one prompt to the configured provider and streams the answer back as text chunks.
public struct AIClient: Sendable {
    public let settings: AISettings
    public let apiKey: String?

    public init(settings: AISettings, apiKey: String?) {
        self.settings = settings
        self.apiKey = apiKey
    }

    /// The model name stored with each answer.
    public var modelLabel: String {
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        return model.isEmpty ? settings.kind.title : model
    }

    /// Why this configuration cannot run yet, if it cannot.
    public var problem: String? {
        if settings.kind.isCLI { return settings.command.isEmpty ? "Set the command in Settings." : nil }
        if settings.baseURL.isEmpty { return "Set the server address in Settings." }
        if (try? endpoint("")) == nil { return "The server address in Settings is not a valid URL." }
        if settings.kind.usesKey, settings.kind != .custom, (apiKey ?? "").isEmpty {
            return "Add your \(settings.kind.title) key in Settings."
        }
        if settings.model.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose a model in Settings." }
        return nil
    }

    /// Streams the next assistant turn. `context` (the video pack) opens the first user message;
    /// `turns` alternate user and assistant and end with the user's new message.
    public func reply(context: String, turns: [ChatMessage]) -> AsyncThrowingStream<String, Error> {
        let system = settings.resolvedSystemPrompt
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let problem { throw NabError(problem) }
                    switch settings.kind {
                    case .claudeCLI, .codexCLI:
                        try await runCommand(
                            system: system, user: Self.flatten(context: context, turns: turns), continuation)
                    case .anthropic:
                        try await anthropic(
                            system: system, messages: Self.anthropicMessages(context: context, turns: turns),
                            continuation)
                    default:
                        try await openAICompatible(
                            system: system, messages: Self.plainMessages(context: context, turns: turns), continuation)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The context rides in its own block with a cache breakpoint, so every follow-up question
    /// re-reads it from the prompt cache instead of paying for it again.
    static func anthropicMessages(context: String, turns: [ChatMessage]) -> [[String: Any]] {
        turns.enumerated().map { index, turn in
            if index == 0 {
                return [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": context, "cache_control": ["type": "ephemeral"]],
                        ["type": "text", "text": turn.text],
                    ],
                ]
            }
            return ["role": turn.role.rawValue, "content": turn.text]
        }
    }

    static func plainMessages(context: String, turns: [ChatMessage]) -> [[String: Any]] {
        turns.enumerated().map { index, turn in
            ["role": turn.role.rawValue, "content": index == 0 ? context + "\n\n" + turn.text : turn.text]
        }
    }

    /// One prompt for command-line tools, which take a single message.
    static func flatten(context: String, turns: [ChatMessage]) -> String {
        guard turns.count > 1, let last = turns.last else { return context + "\n\n" + (turns.first?.text ?? "") }
        let history = turns.dropLast().map { ($0.role == .user ? "User: " : "Assistant: ") + $0.text }.joined(
            separator: "\n\n")
        return context + "\n\n<conversation_so_far>\n" + history + "\n</conversation_so_far>\n\nUser: " + last.text
    }

    /// Models the server offers, for the picker in Settings.
    public func models() async throws -> [String] {
        guard !settings.kind.isCLI else { return [] }
        var request = URLRequest(url: try endpoint("/models"))
        authorize(&request)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Self.check(response, data)
        struct List: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        return try JSONDecoder().decode(List.self, from: data).data.map(\.id).sorted()
    }

    // MARK: Anthropic

    /// Raw HTTP: there is no official Swift SDK. Server-side fallbacks are on for the models that
    /// support them, so a classifier refusal is retried on another model instead of failing.
    private func anthropic(
        system: String, messages: [[String: Any]], _ out: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: try endpoint("/messages"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": settings.model,
            "max_tokens": 64000,
            "stream": true,
            "system": system,
            "messages": messages,
        ]
        if ClaudeModels.withServerFallbacks.contains(settings.model) {
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
            body["fallbacks"] = "default"
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await events(request) { json in
            switch json["type"] as? String {
            case "content_block_delta":
                let delta = json["delta"] as? [String: Any]
                if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String { out.yield(text) }
            case "message_delta":
                if (json["delta"] as? [String: Any])?["stop_reason"] as? String == "refusal" {
                    throw NabError("The model declined to answer.")
                }
            case "error":
                throw NabError(
                    ((json["error"] as? [String: Any])?["message"] as? String) ?? "The API returned an error.")
            default: break
            }
        }
    }

    // MARK: OpenAI-compatible

    private func openAICompatible(
        system: String, messages: [[String: Any]], _ out: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        var request = URLRequest(url: try endpoint("/chat/completions"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if settings.kind == .openRouter {
            request.setValue("https://github.com/tunatavsan/nab", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("Nab", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "model": settings.model,
                "stream": true,
                "messages": [["role": "system", "content": system]] + messages,
            ] as [String: Any])

        try await events(request) { json in
            if let error = json["error"] as? [String: Any] {
                throw NabError(error["message"] as? String ?? "The server returned an error.")
            }
            let choice = (json["choices"] as? [[String: Any]])?.first
            if let text = (choice?["delta"] as? [String: Any])?["content"] as? String { out.yield(text) }
        }
    }

    /// Reads a server-sent event stream and hands each event's JSON data to `handle`.
    private func events(_ request: URLRequest, handle: ([String: Any]) throws -> Void) async throws {
        var request = request
        request.timeoutInterval = 300
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var body = Data()
            for try await byte in bytes.prefix(4096) { body.append(byte) }
            try Self.check(response, body)
        }
        // `AsyncBytes.lines` drops blank lines, and a blank line is what ends an event, so lines are split here.
        var parser = ServerSentEvents()
        var line = Data()
        func dispatch(_ payload: String?) throws -> Bool {
            guard let payload else { return true }
            if payload == "[DONE]" { return false }
            if let json = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] {
                try handle(json)
            }
            return true
        }
        for try await byte in bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            let text = String(decoding: line, as: UTF8.self)
            line.removeAll(keepingCapacity: true)
            guard try dispatch(parser.feed(text)) else { return }
        }
        _ = try dispatch(parser.feed(String(decoding: line, as: UTF8.self)))
        _ = try dispatch(parser.feed(""))
    }

    private func authorize(_ request: inout URLRequest) {
        if settings.kind == .anthropic { request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version") }
        guard let key = apiKey, !key.isEmpty else { return }
        if settings.kind == .anthropic {
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        } else {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
    }

    /// The server address from Settings plus `path`. The address is typed by the user, so it is checked rather
    /// than trusted.
    func endpoint(_ path: String) throws -> URL {
        let base = settings.baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: (base.hasSuffix("/") ? String(base.dropLast()) : base) + path),
            ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil
        else { throw NabError("The server address in Settings is not a valid URL.") }
        return url
    }

    private static func check(_ response: URLResponse, _ body: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        let message =
            ((json?["error"] as? [String: Any])?["message"] as? String)
            ?? String(data: body, encoding: .utf8)?.prefix(200).description
        throw NabError("HTTP \(http.statusCode): \(message ?? "request failed")")
    }

    // MARK: Command line

    /// Runs the CLI in the user's login shell from an empty folder (so no project instructions are
    /// picked up), writes the prompt to stdin and streams stdout.
    private func runCommand(system: String, user: String, _ out: AsyncThrowingStream<String, Error>.Continuation)
        async throws
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", settings.command]
        let folder = FileManager.default.temporaryDirectory.appending(path: "nab-ai", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["NAB_SYSTEM"] = system
        environment["NAB_MODEL"] = settings.model.trimmingCharacters(in: .whitespaces)
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // stderr is drained as it arrives: a command that fills the pipe buffer would otherwise block before it
        // closes stdout, and this side would wait for it forever. Only the end is kept for the error message.
        let errorTail = OutputTail()
        errors.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            // An empty read is the end of the stream; without removing the handler it would fire again at once.
            if chunk.isEmpty { handle.readabilityHandler = nil }
            errorTail.append(chunk)
        }
        // The exit is awaited, not waited for, so a long answer does not hold a thread of the shared pool.
        let exit = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        defer {
            if process.isRunning { process.terminate() }
            errors.fileHandleForReading.readabilityHandler = nil
        }
        try process.run()

        // Codex has no system prompt flag; it reads both from stdin.
        let prompt = settings.kind == .codexCLI ? system + "\n\n" + user : user
        let writer = input.fileHandleForWriting
        // A command that exits without reading its input would raise SIGPIPE here and end the app.
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? writer.write(contentsOf: Data(prompt.utf8))
            try? writer.close()
        }

        // Claude Code's stream-json carries token deltas; any other output is passed through as text.
        let structured = settings.command.contains("stream-json")
        var streamed = false
        var failure: String?
        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                guard structured else {
                    out.yield(line + "\n")
                    continue
                }
                guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    continue
                }
                switch json["type"] as? String {
                case "stream_event":
                    let event = json["event"] as? [String: Any]
                    let delta = event?["delta"] as? [String: Any]
                    if event?["type"] as? String == "content_block_delta", delta?["type"] as? String == "text_delta",
                        let text = delta?["text"] as? String
                    {
                        streamed = true
                        out.yield(text)
                    }
                case "result":
                    let result = json["result"] as? String
                    if json["is_error"] as? Bool == true {
                        failure = result ?? "Claude Code reported an error."
                    } else if !streamed, let result {
                        out.yield(result)
                    }
                default: break
                }
            }
        } onCancel: {
            process.terminate()
        }
        var status: Int32 = 0
        for await code in exit { status = code }
        try Task.checkCancellation()
        if let failure { throw NabError(failure) }
        if status != 0 {
            // The last lines of stderr explain the failure and may still be on their way from the reading queue.
            for _ in 0..<10 where !errorTail.isClosed { try? await Task.sleep(for: .milliseconds(50)) }
            let message = errorTail.text.map { ": \($0)" } ?? "."
            throw NabError("The command failed (exit \(status))\(message)")
        }
    }
}

/// Splits a server-sent event stream into event payloads, following the WHATWG rules Nab needs: `data:` lines
/// of one event are joined with newlines, a blank line ends the event, and comments and other fields are ignored.
struct ServerSentEvents {
    private var data: [String] = []

    /// Takes one line without its line break and returns an event's data when the line completes one.
    mutating func feed(_ line: String) -> String? {
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
        if line.isEmpty {
            defer { data.removeAll() }
            return data.isEmpty ? nil : data.joined(separator: "\n")
        }
        guard line.hasPrefix("data:") else { return nil }
        let value = line.dropFirst(5)
        data.append(String(value.hasPrefix(" ") ? value.dropFirst() : value))
        return nil
    }
}

/// The last few kilobytes a process wrote, collected from a background queue.
private final class OutputTail: Sendable {
    private let state = Mutex((data: Data(), closed: false))
    private let limit = 4096

    /// An empty chunk marks the end of the stream.
    func append(_ chunk: Data) {
        state.withLock {
            if chunk.isEmpty { $0.closed = true }
            $0.data.append(chunk)
            if $0.data.count > limit * 2 { $0.data.removeFirst($0.data.count - limit) }
        }
    }

    var isClosed: Bool { state.withLock { $0.closed } }

    var text: String? {
        let tail = state.withLock { $0.data.suffix(limit) }
        let message = String(decoding: tail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : String(message.suffix(300))
    }
}
