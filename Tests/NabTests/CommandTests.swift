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
