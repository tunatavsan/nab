import Foundation
import Testing

@testable import NabAI

@Suite("AI settings")
struct SettingsTests {
    @Test func promptsAreWrittenInTheChosenLanguage() {
        var settings = AISettings()
        settings.language = "Turkish"
        #expect(settings.resolvedSummaryPrompt.hasPrefix("Summarize in Turkish."))
        #expect(settings.resolvedSystemPrompt.contains("Write in Turkish."))
        #expect(AISettings.languages.contains { $0.name == "Turkish" && $0.native == "Türkçe" })
        #expect(AISettings.languages.map(\.name) == AISettings.languages.map(\.name).sorted())
    }

    @Test func onlyWhatDiffersFromTheDefaultsIsStored() throws {
        var settings = AISettings()
        settings.language = "Turkish"
        settings.command = settings.kind.defaultCommand
        let json = try #require(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        #expect(!json.contains("systemPrompt") && !json.contains("summaryPrompt") && !json.contains("claude -p"))
        let back = try JSONDecoder().decode(AISettings.self, from: Data(json.utf8))
        #expect(back.language == "Turkish" && back.systemPrompt == AISettings.defaultSystemPrompt)
    }

    @Test func storedOldDefaultsFollowNewOnes() throws {
        let old = try #require(AISettings.previousSystemPrompts.first)
        let oldCodex = try #require(AISettings.previousCommands.first { $0.hasPrefix("codex") })
        let stored: [String: Any] = [
            "kind": "codexCLI", "language": "German", "systemPrompt": old,
            // Dictionaries keyed by an enum are stored as [key, value, ...] arrays.
            "summaryPrompt": "Three bullets only.", "commands": ["codexCLI", oldCodex],
        ]
        let settings = try JSONDecoder().decode(AISettings.self, from: JSONSerialization.data(withJSONObject: stored))
        #expect(settings.systemPrompt == AISettings.defaultSystemPrompt)
        #expect(settings.command == ProviderKind.codexCLI.defaultCommand)
        #expect(settings.command.contains("--sandbox read-only"))
        #expect(settings.summaryPrompt == "Three bullets only.")
        #expect(settings.language == "German")
    }

    @Test func commandLineProvidersRunWithoutTools() {
        #expect(ProviderKind.claudeCLI.defaultCommand.contains(#"--tools """#))
        #expect(ProviderKind.codexCLI.defaultCommand.contains("--sandbox read-only"))
    }
}
