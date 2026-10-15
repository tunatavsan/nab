import Foundation
import Testing

@testable import NabAI

@Suite("Model names")
struct ModelNamesTests {
    @Test func readsClaudeIDs() {
        #expect(ModelNames.display("claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(ModelNames.display("claude-opus-5-5") == "Opus 5.5")
        #expect(ModelNames.display("claude-haiku-5-5") == "Haiku 5.5")
        #expect(ModelNames.display("claude-fable-5-1") == "Fable 5.1")
        #expect(ModelNames.display("claude-opus-5") == "Opus 5")
    }

    @Test func readsOlderOrderingAndDates() {
        #expect(ModelNames.display("claude-3-5-sonnet-20241022") == "Sonnet 3.5")
        #expect(ModelNames.display("claude-sonnet-4-20250514") == "Sonnet 4")
    }

    @Test func leavesOtherIDsAlone() {
        #expect(ModelNames.display("gpt-4o") == "gpt-4o")
        #expect(ModelNames.display("qwen3:27b") == "qwen3:27b")
        #expect(ModelNames.display("  ") == "")
        #expect(ModelNames.display("claude") == "claude")
    }

    @Test func listsModelsPerProvider() {
        #expect(ModelNames.choices(for: .claudeCLI) == ClaudeModels.current)
        #expect(ModelNames.choices(for: .anthropic) == ClaudeModels.current)
        #expect(ModelNames.choices(for: .ollama).isEmpty)
    }
}
