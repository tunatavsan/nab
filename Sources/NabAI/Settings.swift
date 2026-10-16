import Foundation
import NabCore

/// The service that answers. Every HTTP provider except Anthropic speaks the OpenAI chat format,
/// so local servers (Ollama, LM Studio) and gateways (OpenRouter) need only a base URL.
public enum ProviderKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCLI, codexCLI, anthropic, openAI, openRouter, ollama, lmStudio, custom

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .claudeCLI: "Claude Code (claude -p)"
        case .codexCLI: "Codex CLI"
        case .anthropic: "Anthropic API"
        case .openAI: "OpenAI API"
        case .openRouter: "OpenRouter"
        case .ollama: "Ollama (local)"
        case .lmStudio: "LM Studio (local)"
        case .custom: "OpenAI-compatible server"
        }
    }

    public var isCLI: Bool { self == .claudeCLI || self == .codexCLI }
    public var usesKey: Bool { [.anthropic, .openAI, .openRouter, .custom].contains(self) }

    public var defaultBaseURL: String {
        switch self {
        case .anthropic: "https://api.anthropic.com/v1"
        case .openAI: "https://api.openai.com/v1"
        case .openRouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmStudio: "http://localhost:1234/v1"
        case .custom, .claudeCLI, .codexCLI: ""
        }
    }

    public var defaultModel: String { self == .anthropic ? "claude-opus-5-5" : "" }

    /// Offered in the model menu when the provider cannot list its own models.
    public var suggestedModels: [String] {
        self == .claudeCLI || self == .anthropic ? ClaudeModels.current : []
    }

    /// Reasoning effort levels the provider's CLI accepts, lowest first; empty when the provider has no such setting.
    /// The API providers stay empty: no official reference was checked for a request parameter (K3), and the local
    /// servers have none. Levels are not filtered by model; a CLI rejects what a model cannot take and says so.
    public var effortLevels: [String] {
        switch self {
        case .claudeCLI: ["low", "medium", "high", "xhigh", "max"]
        case .codexCLI: ["low", "medium", "high", "xhigh"]
        default: []
        }
    }

    /// Run in the user's login shell so PATH and sign-in match their terminal. The prompt goes in on
    /// stdin; `$NAB_SYSTEM`, `$NAB_MODEL` and `$NAB_EFFORT` carry the system prompt, model and effort. The model flag and its value
    /// are two expansions: zsh does not split `${NAB_MODEL:+--model "$NAB_MODEL"}` into words, so the CLI
    /// received "--model <id>" as one unknown option and failed whenever a model was chosen.
    public var defaultCommand: String {
        switch self {
        case .claudeCLI:
            #"claude -p --system-prompt "$NAB_SYSTEM" ${NAB_MODEL:+--model} ${NAB_MODEL:+"$NAB_MODEL"} ${NAB_EFFORT:+--effort} ${NAB_EFFORT:+"$NAB_EFFORT"} --tools "" --strict-mcp-config --no-session-persistence --output-format stream-json --include-partial-messages --verbose"#
        case .codexCLI:
            #"codex exec --skip-git-repo-check --sandbox read-only ${NAB_MODEL:+-m} ${NAB_MODEL:+"$NAB_MODEL"} ${NAB_EFFORT:+-c} ${NAB_EFFORT:+"model_reasoning_effort=$NAB_EFFORT"} -"#
        default: ""
        }
    }
}

/// Current Claude models, shared by the model menu and the Anthropic request.
public enum ClaudeModels {
    public static let current = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
    /// Models that accept `fallbacks`, so a refusal is retried on another model instead of failing.
    static let withServerFallbacks: Set<String> = [
        "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5",
    ]
}

public struct AISettings: Codable, Sendable, Equatable {
    public var kind: ProviderKind = .claudeCLI
    public var models: [ProviderKind: String] = [:]
    public var baseURLs: [ProviderKind: String] = [:]
    public var commands: [ProviderKind: String] = [:]
    /// Reasoning effort per provider; absent means the CLI's own default.
    public var efforts: [ProviderKind: String] = [:]
    /// How the assistant behaves in every chat.
    public var systemPrompt = AISettings.defaultSystemPrompt
    /// What "Summarize" asks for.
    public var summaryPrompt = AISettings.defaultSummaryPrompt
    /// The language answers are written in; defaults to the Mac's language.
    public var language = AISettings.systemLanguage

    public init() {}

    public var model: String {
        get { models[kind] ?? kind.defaultModel }
        set { models[kind] = newValue }
    }
    public var baseURL: String {
        get { baseURLs[kind] ?? kind.defaultBaseURL }
        set { baseURLs[kind] = newValue }
    }
    public var command: String {
        get { commands[kind] ?? kind.defaultCommand }
        set { commands[kind] = newValue }
    }

    /// True when the provider is a CLI whose command never reads `$NAB_EFFORT`, so the effort setting has no effect.
    public var commandIgnoresEffort: Bool {
        kind.isCLI && !kind.effortLevels.isEmpty && !command.contains("NAB_EFFORT")
    }

    public var effort: String {
        get { efforts[kind] ?? "" }
        set { efforts[kind] = newValue.isEmpty ? nil : newValue }
    }

    public var resolvedSystemPrompt: String {
        systemPrompt.replacingOccurrences(of: "{language}", with: language)
    }

    public var resolvedSummaryPrompt: String {
        summaryPrompt.replacingOccurrences(of: "{language}", with: language)
    }

    enum CodingKeys: String, CodingKey {
        case kind, models, baseURLs, commands, efforts, systemPrompt, summaryPrompt, language
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fresh = AISettings()
        // Each field stands alone: one value this build cannot read (a provider from a newer version, a wrong type)
        // costs that value, not the user's models, commands and prompts.
        kind = (try? c.decodeIfPresent(ProviderKind.self, forKey: .kind)) ?? fresh.kind
        models = Self.lenientMap(c, .models)
        baseURLs = Self.lenientMap(c, .baseURLs)
        commands = Self.lenientMap(c, .commands).filter { !Self.previousCommands.contains($0.value) }
        efforts = Self.lenientMap(c, .efforts)
        systemPrompt =
            ((try? c.decodeIfPresent(String.self, forKey: .systemPrompt)) ?? nil)
            .flatMap { Self.previousSystemPrompts.contains($0) ? nil : $0 } ?? fresh.systemPrompt
        summaryPrompt =
            ((try? c.decodeIfPresent(String.self, forKey: .summaryPrompt)) ?? nil)
            .flatMap { Self.previousSummaryPrompts.contains($0) ? nil : $0 } ?? fresh.summaryPrompt
        language = ((try? c.decodeIfPresent(String.self, forKey: .language)) ?? nil) ?? fresh.language
    }

    /// A provider-keyed map read entry by entry: a key this build does not know is dropped alone. Swift stores such
    /// a map as a flat array `[key, value, key, value, …]`.
    private static func lenientMap(
        _ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys
    ) -> [ProviderKind: String] {
        guard let flat = (try? c.decodeIfPresent([String].self, forKey: key)) ?? nil else { return [:] }
        var map: [ProviderKind: String] = [:]
        for index in stride(from: 0, to: flat.count - 1, by: 2) {
            if let kind = ProviderKind(rawValue: flat[index]) { map[kind] = flat[index + 1] }
        }
        return map
    }

    /// Stores only what differs from the built-in defaults, so improved defaults reach everyone who
    /// never edited them.
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(models.filter { !$0.value.isEmpty && $0.value != $0.key.defaultModel }, forKey: .models)
        try c.encode(baseURLs.filter { $0.value != $0.key.defaultBaseURL }, forKey: .baseURLs)
        try c.encode(commands.filter { $0.value != $0.key.defaultCommand }, forKey: .commands)
        try c.encode(efforts.filter { !$0.value.isEmpty }, forKey: .efforts)
        if systemPrompt != Self.defaultSystemPrompt { try c.encode(systemPrompt, forKey: .systemPrompt) }
        if summaryPrompt != Self.defaultSummaryPrompt { try c.encode(summaryPrompt, forKey: .summaryPrompt) }
        try c.encode(language, forKey: .language)
    }

    public static let defaultSystemPrompt = """
        You are the assistant inside Nab. The user collected one or more videos; their details and timecoded transcripts are in the first message, inside <nab_context>.

        - Answer from the transcripts. When they do not cover something, say so; add general knowledge only when you label it as such.
        - Cite the moment behind each claim: [12:40] when there is one video, [2 12:40] for video 2 when there are several.
        - Write in {language}. If the user asks a question in another language, answer that question in their language.
        - Be direct. Use Markdown lists and bold sparingly. No preamble, no closing offers.
        """

    public static let defaultSummaryPrompt = """
        Summarize in {language}. Open with one sentence: what the video is and its central claim. Then **Key points**: 3 to 7 bullets, each ending with its timecode. Then **Worth acting on**: up to 3 bullets, only if the video teaches something practical. With several videos, do this for each under its title, then add **Across the videos**: where they agree and where they differ. Auto-generated captions garble names and numbers; flag doubtful ones instead of guessing.
        """

    /// Built-in values from builds before this one, including those before the first public release. A stored
    /// copy of one means "the default", so it follows later improvements instead of freezing the old text.
    static let previousSystemPrompts: Set<String> = [
        """
        You are the assistant inside Nab. The user collected one or more videos; their details and timecoded transcripts are in the first message, inside <nab_context>.

        - Answer from the transcripts. When they do not cover something, say so; add general knowledge only when you label it as such.
        - Cite the moment behind each claim: [12:40] when there is one video, [2 12:40] for video 2 when there are several.
        - Write in {language}, unless the user writes in another language; then answer in theirs.
        - Be direct. Use Markdown lists and bold sparingly. No preamble, no closing offers.
        """
    ]
    static let previousSummaryPrompts: Set<String> = [
        """
        Summarize. Open with one sentence: what the video is and its central claim. Then **Key points**: 3 to 7 bullets, each ending with its timecode. Then **Worth acting on**: up to 3 bullets, only if the video teaches something practical. With several videos, do this for each under its title, then add **Across the videos**: where they agree and where they differ. Auto-generated captions garble names and numbers; flag doubtful ones instead of guessing.
        """
    ]
    static let previousCommands: Set<String> = [
        #"claude -p --system-prompt "$NAB_SYSTEM" ${NAB_MODEL:+--model} ${NAB_MODEL:+"$NAB_MODEL"} --tools "" --strict-mcp-config --no-session-persistence --output-format stream-json --include-partial-messages --verbose"#,
        #"codex exec --skip-git-repo-check --sandbox read-only ${NAB_MODEL:+-m} ${NAB_MODEL:+"$NAB_MODEL"} -"#,
        #"claude -p --system-prompt "$NAB_SYSTEM" ${NAB_MODEL:+--model "$NAB_MODEL"} --tools "" --strict-mcp-config --no-session-persistence"#,
        #"codex exec --skip-git-repo-check ${NAB_MODEL:+-m "$NAB_MODEL"} -"#,
        #"claude -p --system-prompt "$NAB_SYSTEM" ${NAB_MODEL:+--model "$NAB_MODEL"} --tools "" --strict-mcp-config --no-session-persistence --output-format stream-json --include-partial-messages --verbose"#,
        #"codex exec --skip-git-repo-check --sandbox read-only ${NAB_MODEL:+-m "$NAB_MODEL"} -"#,
    ]

    /// Languages offered for answers, by English name. The stored value is the English name, which the prompts use.
    public static let languages: [(name: String, native: String)] =
        "ar de el en es fa fr he hi id it ja ko nl pl pt ru sv tr uk zh-Hans zh-Hant".split(separator: " ").map {
            let code = String($0)
            let native = Locale(identifier: code).localizedString(forIdentifier: code) ?? code
            return (
                Locale(identifier: "en").localizedString(forIdentifier: code) ?? code,
                native.prefix(1).uppercased(with: Locale(identifier: code)) + native.dropFirst()
            )
        }
        .sorted { $0.name < $1.name }

    static var systemLanguage: String {
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    private static let defaultsKey = "ai.settings"

    /// Whether the user ever saved a provider choice; false on a fresh install.
    public static var isSaved: Bool { UserDefaults.standard.data(forKey: defaultsKey) != nil }

    public static func load() -> AISettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return AISettings() }
        do {
            return try JSONDecoder().decode(AISettings.self, from: data)
        } catch {
            NSLog("Nab: AI settings could not be read and were reset: \(error)")
            return AISettings()
        }
    }

    public func save() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey)
        } catch {
            NSLog("Nab: AI settings could not be saved: \(error)")
        }
    }
}
