import Foundation
import NabCore
import Testing

@testable import NabAI

/// The command-line providers, tested against small shell commands in place of a real CLI.
@Suite("Command-line providers", .timeLimit(.minutes(1)))
struct CommandTests {
    private func run(_ command: String, prompt: String = "question") async throws -> String {
        var settings = AISettings()
        settings.command = command
        let client = AIClient(settings: settings, apiKey: nil)
        return try await collect(client.reply(context: prompt, turns: [ChatMessage(role: .user, text: "q")]))
    }

    /// The arguments a default command passes to its CLI, read by a shell function standing in for it.
    private func arguments(_ kind: ProviderKind, model: String, shell: String) throws -> [String] {
        let tool = kind == .claudeCLI ? "claude" : "codex"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", "\(tool)() { printf '%s\\n' \"$@\"; }; " + kind.defaultCommand]
        process.environment = ["NAB_MODEL": model, "NAB_SYSTEM": "system"]
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash"])
    func chosenModelReachesTheCLIAsItsOwnArgument(shell: String) throws {
        for (kind, flag) in [(ProviderKind.claudeCLI, "--model"), (.codexCLI, "-m")] {
            let args = try arguments(kind, model: "claude-sonnet-5-5", shell: shell)
            let index = try #require(args.firstIndex(of: flag), "\(kind) under \(shell): \(args)")
            #expect(args.indices.contains(index + 1) && args[index + 1] == "claude-sonnet-5-5")
            let empty = try arguments(kind, model: "", shell: shell)
            #expect(!empty.contains(flag) && !empty.contains(""))
        }
    }

    /// The whole path of a model switch: the card's id lands in the settings, and the command the client runs
    /// hands it to the CLI as `--model` plus a value.
    @Test func choosingSonnetPutsItInTheSettingsAndTheCommand() async throws {
        var settings = AISettings()
        settings.kind = .claudeCLI
        let sonnet = try #require(
            ModelChoices.featured(for: .claudeCLI, available: []).first { $0.name == "Sonnet 5.5" })
        settings.model = sonnet.id
        #expect(settings.models[.claudeCLI] == "claude-sonnet-5-5")
        let stored = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        #expect(stored.kind == .claudeCLI && stored.model == "claude-sonnet-5-5")

        // A stand-in `claude` answers with the value that follows a separate `--model` argument, if any.
        settings.command =
            #"claude() { while [ $# -gt 0 ]; do [ "$1" = --model ] && m="$2"; shift; done; "#
            + #"printf '{"type":"result","is_error":false,"result":"%s"}\n' "$m"; }; "# + settings.command
        let client = AIClient(settings: settings, apiKey: nil)
        let answer = try await collect(client.reply(context: "ctx", turns: [ChatMessage(role: .user, text: "q")]))
        #expect(answer == "claude-sonnet-5-5")
    }

    @Test func commandThatIgnoresItsInputDoesNotKillTheApp() async throws {
        // Larger than a pipe buffer, so the write is still in progress when the command exits.
        #expect(try await run("echo ok", prompt: String(repeating: "x", count: 1_000_000)) == "ok\n")
    }

    @Test func chattyStderrDoesNotStallTheAnswer() async throws {
        #expect(try await run("head -c 300000 /dev/zero | tr '\\0' x >&2; echo done") == "done\n")
    }

    @Test func failingCommandReportsItsStderr() async throws {
        do {
            _ = try await run("echo 'not signed in' >&2; exit 3")
            Issue.record("expected the command to fail")
        } catch {
            #expect(error.localizedDescription.contains("exit 3"))
            #expect(error.localizedDescription.contains("not signed in"))
        }
    }

    @Test func plainOutputKeepsParagraphBreaks() async throws {
        #expect(try await run("printf 'one\\n\\ntwo\\n'") == "one\n\ntwo\n")
    }

    @Test func claudeCodeStreamJSONIsReadAsTokenDeltas() async throws {
        let events = [
            #"{"type":"system","subtype":"init"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"lo"}}}"#,
            #"{"type":"result","is_error":false,"result":"Hello"}"#,
        ]
        // The trailing comment marks the command as stream-json, the way Claude Code's flag does.
        let command =
            "cat >/dev/null; printf '%s\\n' " + events.map { "'\($0)'" }.joined(separator: " ") + " # stream-json"
        #expect(try await run(command) == "Hello")
    }

    @Test func stoppingAnAnswerEndsACommandThatIgnoresSIGTERM() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "nab-test-\(UUID().uuidString).pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let answer = Task { try await run("echo $$ > '\(pidFile.path)'; trap '' TERM; sleep 30") }
        var pid: pid_t?
        for _ in 0..<100 where pid == nil {
            try await Task.sleep(for: .milliseconds(50))
            pid = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        let running = try #require(pid)
        answer.cancel()
        _ = await answer.result
        try await Task.sleep(for: .seconds(3))
        #expect(kill(running, 0) != 0, "the command is still running")
    }
}
