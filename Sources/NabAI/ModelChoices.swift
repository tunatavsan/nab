import Foundation

/// One model a provider offers, as the settings page shows it.
public struct ModelChoice: Equatable, Sendable, Identifiable {
    /// The value stored and sent as the model. Empty means "the CLI's own default": no model flag at all.
    public let id: String
    public let name: String
    public let note: String

    public init(id: String, name: String, note: String) {
        self.id = id
        self.name = name
        self.note = note
    }
}

/// Which models the settings page puts in front of the user, per provider. Pure data and functions.
public enum ModelChoices {
    public static let opus = ModelChoice(
        id: "claude-opus-5-5", name: ModelNames.display("claude-opus-5-5"), note: "Most capable, slower")
    public static let sonnet = ModelChoice(
        id: "claude-sonnet-5-5", name: ModelNames.display("claude-sonnet-5-5"), note: "Balanced")
    public static let haiku = ModelChoice(
        id: "claude-haiku-5-5", name: ModelNames.display("claude-haiku-5-5"), note: "Fastest")
    public static let claude = [opus, sonnet, haiku]

    /// The CLI chooses; nothing is passed with `--model`.
    public static func standard(for kind: ProviderKind) -> ModelChoice? {
        switch kind {
        case .claudeCLI: ModelChoice(id: "", name: "Default", note: "Set by Claude Code")
        case .codexCLI: ModelChoice(id: "", name: "Default", note: "Set by Codex")
        default: nil
        }
    }

    /// The most useful choices for a provider, at most three. `available` is the provider's own model list
    /// (fetched, or the suggestions when it cannot list them).
    public static func featured(for kind: ProviderKind, available: [String]) -> [ModelChoice] {
        switch kind {
        case .claudeCLI, .anthropic:
            return claude
        case .codexCLI:
            return []
        case .openRouter:
            return claude.map { ModelChoice(id: "anthropic/" + $0.id, name: $0.name, note: $0.note) }
        case .openAI:
            let chat = available.filter(isOpenAIChatModel).sorted(by: >)
            return chat.prefix(3).map { ModelChoice(id: $0, name: $0, note: "From your account") }
        case .ollama, .lmStudio:
            return available.prefix(3).map { ModelChoice(id: $0, name: $0, note: "Installed") }
        case .custom:
            return available.prefix(3).map { ModelChoice(id: $0, name: $0, note: "From the server") }
        }
    }

    /// Everything but "Other…": the featured models, then the CLI default.
    public static func choices(for kind: ProviderKind, available: [String]) -> [ModelChoice] {
        featured(for: kind, available: available) + [standard(for: kind)].compactMap { $0 }
    }

    /// What the "Other…" card says before a custom model is typed.
    public static func otherNote(for kind: ProviderKind) -> String {
        kind == .ollama || kind == .lmStudio ? "Type a model name" : "Type a model ID"
    }

    public enum Selection: Equatable, Sendable {
        case choice(String)
        case other(String)
    }

    /// Which card is selected for the stored model: a listed choice, or "Other…" holding that id.
    public static func selection(model: String, among choices: [ModelChoice]) -> Selection {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        if let match = choices.first(where: { $0.id == trimmed }) { return .choice(match.id) }
        return .other(trimmed)
    }

    /// The model to store when a provider that cannot run without one has none yet.
    public static func initialModel(for kind: ProviderKind, current: String, available: [String]) -> String? {
        guard !kind.isCLI, current.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return featured(for: kind, available: available).first?.id
    }

    /// A readable name for a stored model id.
    public static func displayName(for id: String) -> String {
        ModelNames.display(id)
    }

    private static func isOpenAIChatModel(_ id: String) -> Bool {
        guard id.hasPrefix("gpt-") else { return false }
        let other = [
            "audio", "realtime", "transcribe", "tts", "image", "search", "instruct", "embedding", "moderation",
        ]
        return !other.contains { id.contains($0) } && !id.contains(":")
    }
}
