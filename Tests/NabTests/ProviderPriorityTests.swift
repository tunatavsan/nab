import Testing

@testable import NabAI

@Suite struct ProviderPriorityTests {
    @Test func theListedOrderWinsWhateverAnsweredFirst() {
        let ready: Set<ProviderKind> = [.lmStudio, .codexCLI, .ollama]
        #expect(ProviderPriority.preselected(ready: ready, current: .anthropic) == .codexCLI)
    }

    @Test func aReadyCurrentChoiceStays() {
        #expect(ProviderPriority.preselected(ready: [.claudeCLI, .lmStudio], current: .lmStudio) == .lmStudio)
    }

    @Test func nothingReadyPreselectsNothing() {
        #expect(ProviderPriority.preselected(ready: [], current: .claudeCLI) == nil)
    }
}
