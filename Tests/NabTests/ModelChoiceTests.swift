import Foundation
import Testing

@testable import NabAI

@Suite("Model choices and provider status")
struct ModelChoiceTests {
    @Test func claudeOffersOpusSonnetHaikuWithNotes() {
        let choices = ModelChoices.featured(for: .anthropic, available: [])
        #expect(choices.map(\.id) == ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"])
        #expect(choices.map(\.name) == ["Opus 5.5", "Sonnet 5.5", "Haiku 5.5"])
        #expect(choices.map(\.note) == ["Most capable, slower", "Balanced", "Fastest"])
        #expect(ModelChoices.displayName(for: "claude-sonnet-5-5") == "Sonnet 5.5")
        #expect(ModelChoices.displayName(for: "mystery") == "mystery")
    }

    @Test func cliProvidersGetADefaultThatSendsNoModel() {
        for kind in [ProviderKind.claudeCLI, .codexCLI] {
            let standard = ModelChoices.choices(for: kind, available: []).last
            #expect(standard?.name == "Default" && standard?.id == "")
        }
        #expect(ModelChoices.standard(for: .anthropic) == nil)
    }

    @Test func localServersOfferTheirInstalledModels() {
        let choices = ModelChoices.featured(for: .ollama, available: ["a", "b", "c", "d"])
        #expect(choices.map(\.id) == ["a", "b", "c"] && choices.allSatisfy { $0.note == "Installed" })
    }

    @Test func openAIListsChatModelsNewestFirstWithoutNoise() {
        let available = ["gpt-4o", "text-embedding-3", "gpt-5", "gpt-4o-realtime-preview", "whisper-1", "gpt-4o-mini"]
        #expect(
            ModelChoices.featured(for: .openAI, available: available).map(\.id) == ["gpt-5", "gpt-4o-mini", "gpt-4o"])
    }

    @Test func selectionFallsToOtherForAnUnlistedModel() {
        let choices = ModelChoices.choices(for: .claudeCLI, available: [])
        #expect(ModelChoices.selection(model: "claude-sonnet-5-5", among: choices) == .choice("claude-sonnet-5-5"))
        #expect(ModelChoices.selection(model: "", among: choices) == .choice(""))
        #expect(ModelChoices.selection(model: " my-model ", among: choices) == .other("my-model"))
    }

    @Test func aProviderThatNeedsAModelGetsOneOnlyWhenEmpty() {
        #expect(ModelChoices.initialModel(for: .ollama, current: "", available: ["qwen"]) == "qwen")
        #expect(ModelChoices.initialModel(for: .ollama, current: "llama", available: ["qwen"]) == nil)
        #expect(ModelChoices.initialModel(for: .claudeCLI, current: "", available: []) == nil)
    }

    @Test func statusLabels() {
        #expect(
            ProviderStatus.cli(found: true).label == "Ready" && ProviderStatus.cli(found: false).label == "Not found")
        #expect(
            ProviderStatus.key(saved: false).label == "Add key" && ProviderStatus.key(saved: true).label == "Key saved")
        #expect(ProviderStatus.server(running: true).label == "Running")
        #expect(ProviderStatus.server(running: false).label == "Not running")
        #expect(ProviderStatus.address("http://x/v1").label == "http://x/v1")
        #expect(ProviderStatus.ready.isPositive && !ProviderStatus.notRunning.isPositive)
    }

    @Test func providersAreSplitIntoCommonAndMore() {
        #expect(Set(ProviderKind.common + ProviderKind.more) == Set(ProviderKind.allCases))
        #expect(ProviderKind.common.count == 5)
    }

    @Test func executableIsTheFirstWordOfTheCommand() {
        #expect(ProviderProbe.executable(in: ProviderKind.claudeCLI.defaultCommand) == "claude")
        #expect(ProviderProbe.executable(in: "FOO=1 /opt/bin/codex exec") == "/opt/bin/codex")
        #expect(ProviderProbe.executable(in: "") == nil)
        #expect(ProviderProbe.executable(in: "$(rm -rf x)") == nil)
    }

    @Test func modelsURLFollowsTheServerAddress() {
        #expect(
            ProviderProbe.modelsURL(baseURL: "http://localhost:11434/v1/")?.absoluteString
                == "http://localhost:11434/v1/models")
        #expect(ProviderProbe.modelsURL(baseURL: "nonsense") == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func cliLookupUsesTheLoginShell() async {
        #expect(await ProviderProbe.cliFound(command: "ls -l"))
        #expect(!(await ProviderProbe.cliFound(command: "nab-no-such-tool-xyz")))
    }

    @Test(.timeLimit(.minutes(1)))
    func aClosedPortIsNotRunning() async {
        #expect(!(await ProviderProbe.serverRunning(baseURL: "http://127.0.0.1:1/v1")))
    }
}
