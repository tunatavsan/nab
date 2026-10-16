import Foundation
import Testing

@testable import NabAI

@Suite("Effort")
struct EffortTests {
    /// The words the shell hands the program, one per line, for `command` with `env`.
    private func argv(_ command: String, env: [String: String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", "printf '%s\\n' \(command)"]
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test func levelsExistOnlyWhereACLIAcceptsThem() {
        #expect(ProviderKind.claudeCLI.effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(ProviderKind.codexCLI.effortLevels == ["low", "medium", "high", "xhigh"])
        for kind in ProviderKind.allCases where !kind.isCLI { #expect(kind.effortLevels.isEmpty) }
    }

    @Test func claudeGetsTheFlagFromTheEnvironmentOnly() throws {
        let command = ProviderKind.claudeCLI.defaultCommand
        #expect(!command.contains("xhigh"))
        let withEffort = try argv(command, env: ["NAB_SYSTEM": "s", "NAB_EFFORT": "xhigh"])
        let at = try #require(withEffort.firstIndex(of: "--effort"))
        #expect(withEffort[at + 1] == "xhigh")
        let without = try argv(command, env: ["NAB_SYSTEM": "s", "NAB_EFFORT": ""])
        #expect(!without.contains("--effort") && !without.contains(""))
    }

    @Test func codexGetsTheConfigOverride() throws {
        let words = try argv(ProviderKind.codexCLI.defaultCommand, env: ["NAB_EFFORT": "high"])
        let at = try #require(words.firstIndex(of: "-c"))
        #expect(words[at + 1] == "model_reasoning_effort=high")
        let none = try argv(ProviderKind.codexCLI.defaultCommand, env: [:])
        #expect(!none.contains("-c"))
    }

    @Test func theEffortReachesAnyCommandThroughTheEnvironment() {
        var settings = AISettings()
        settings.kind = .codexCLI
        settings.command = "my-wrapper"
        settings.effort = "medium"
        #expect(AIClient.commandEnvironment(settings: settings, system: "s")["NAB_EFFORT"] == "medium")
        settings.effort = ""
        #expect(AIClient.commandEnvironment(settings: settings, system: "s")["NAB_EFFORT"] == "")
    }

    @Test func oldSettingsOpenWithoutEfforts() throws {
        let old = #"{"kind":"claudeCLI","models":["claudeCLI","claude-haiku-5-5"],"language":"German"}"#
        let settings = try JSONDecoder().decode(AISettings.self, from: Data(old.utf8))
        #expect(settings.efforts.isEmpty && settings.model == "claude-haiku-5-5" && settings.language == "German")
    }

    @Test func effortsAreStoredPerProvider() throws {
        var settings = AISettings()
        settings.effort = "high"
        let back = try JSONDecoder().decode(AISettings.self, from: JSONEncoder().encode(settings))
        #expect(back.effort == "high")
        settings.effort = ""
        let json = try #require(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        #expect(json.contains(#""efforts":[]"#))
    }
}
