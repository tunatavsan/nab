import AppKit
import NabAI
import NabCore
import SwiftUI

/// The AI section: provider, then model, key, language, a test and the advanced settings.
struct SettingsAICard: View {
    @Bindable var assistant: Assistant
    @State private var key = ""
    /// The provider the key field belongs to. It trails `kind` until the typed key is saved.
    @State private var keyKind = ProviderKind.claudeCLI
    @State private var keyError: String?
    @FocusState private var keyFocused: Bool
    @State private var models: [String] = []
    @State private var test = TestState.idle
    @State private var statuses: [ProviderKind: ProviderStatus] = [:]
    @State private var showMore = false
    @State private var showAdvanced = false
    @State private var typingModel = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum TestState: Equatable {
        case idle, running
        case passed(String)
        case failed(String)
    }

    private var kind: ProviderKind { assistant.settings.kind }

    /// The pop-ups and fields on the right of a row share this width.
    private static let fieldWidth: CGFloat = 260

    var body: some View {
        SettingsSection(title: "AI", footnote: "Used for summaries, session chats and the floating window.") {
            providerGroup
            if kind.isCLI { CLIGuide(kind: kind).padding(.horizontal, Space.l) }
            SettingsGroup {
                modelRow
                if modelIDVisible { modelIDRow }
                if !kind.effortLevels.isEmpty { effortRow }
                languageRow
                if kind.usesKey { keyRow }
                if kind == .custom { serverRow }
                testRow
                advancedHeader
                if showAdvanced { advanced }
            }
        }
        .onAppear {
            keyKind = kind
            key = assistant.key(for: kind)
        }
        .onChange(of: kind) { _, new in
            guard new != keyKind else { return }
            // The field still holds the previous provider's key. If it cannot be saved, stay on that provider
            // with the error showing, rather than dropping what the user typed.
            guard saveKey() else {
                assistant.settings.kind = keyKind
                return
            }
            keyKind = new
            key = assistant.key(for: new)
            keyError = nil
            test = .idle
            typingModel = false
        }
        .onChange(of: assistant.settings.model) { _, _ in test = .idle }
        .onChange(of: keyFocused) { _, focused in
            if !focused { saveKey() }
        }
        .onDisappear { saveKey() }
        .task(id: "\(kind.rawValue)|\(assistant.settings.baseURL)|\(key.count)") { await loadModels() }
        .task(id: probeID) { await probe() }
    }

    // MARK: Providers

    private var moreExpanded: Bool { showMore || ProviderKind.more.contains(kind) }

    private var providerGroup: some View {
        SettingsGroup {
            ForEach(ProviderKind.common, id: \.self) { row($0) }
            moreRow
            if moreExpanded {
                ForEach(ProviderKind.more, id: \.self) { row($0) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
    }

    private func row(_ provider: ProviderKind) -> some View {
        let on = provider == kind
        let status = status(of: provider)
        return Button {
            assistant.settings.kind = provider
        } label: {
            HStack(spacing: Space.m) {
                radio(on: on)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(provider.shortTitle).font(Typeface.body).foregroundStyle(Palette.ink)
                    Text(provider.blurb).font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                Text(status.label)
                    .font(Typeface.meta)
                    .foregroundStyle(status.isPositive ? Palette.accentInk : Palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            .settingsRowFrame(tall: true)
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityLabel("\(provider.shortTitle), \(provider.blurb), \(status.label)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func radio(on: Bool) -> some View {
        Circle()
            .strokeBorder(on ? Palette.accentInk : Palette.lineStrong, lineWidth: 1.5)
            .frame(width: 16, height: 16)
            .overlay { Circle().fill(on ? Palette.accentInk : .clear).frame(width: 6, height: 6) }
    }

    private var moreRow: some View {
        Button {
            withAnimation(Motion.resolved(Motion.settle, reduceMotion: reduceMotion)) { showMore.toggle() }
        } label: {
            HStack(spacing: Space.s) {
                Text("More providers").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                if !moreExpanded {
                    Text("OpenRouter, LM Studio or your own server").font(Typeface.meta)
                        .foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.right").font(Typeface.iconMicro).foregroundStyle(Palette.inkSecondary)
                    .rotationEffect(.degrees(moreExpanded ? 90 : 0))
            }
            .settingsRowFrame()
            .padding(.leading, 28)
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityLabel(moreExpanded ? "Fewer providers" : "More providers")
    }

    private func status(of provider: ProviderKind) -> ProviderStatus {
        switch provider {
        case .anthropic, .openAI, .openRouter: .key(saved: !assistant.key(for: provider).isEmpty)
        case .custom: .address(assistant.settings.baseURLs[.custom] ?? "")
        default: statuses[provider] ?? .checking
        }
    }

    // MARK: Key and server

    private var keyRow: some View {
        SettingsRow(title: "API key") {
            if let keyError {
                SettingsDetail(text: keyError, isError: true).textSelection(.enabled)
            } else {
                SettingsDetail(text: "Stored in your keychain")
            }
        } control: {
            SecureField(
                "API key", text: $key, prompt: Text(kind == .custom ? "Optional" : "Paste your key")
            )
            .labelsHidden()
            .font(Typeface.body)
            .settingsField(focus: $keyFocused)
            .onSubmit { saveKey() }
            .frame(width: Self.fieldWidth)
            .accessibilityLabel("\(kind.shortTitle) API key")
        }
    }

    private var serverRow: some View {
        SettingsRow(title: "Server address") {
            serverField
        }
    }

    private var serverField: some View {
        TextField("Server address", text: $assistant.settings.baseURL, prompt: Text(kind.defaultBaseURL))
            .labelsHidden()
            .font(Typeface.code)
            .settingsField()
            .frame(width: Self.fieldWidth)
            .accessibilityLabel("Server address")
    }

    // MARK: Model

    private var choices: [ModelChoice] { ModelChoices.choices(for: kind, available: models) }

    private var selection: ModelChoices.Selection {
        ModelChoices.selection(model: assistant.settings.model, among: choices)
    }

    private var otherSelected: Bool {
        if case .other = selection { return true }
        return typingModel
    }

    private var modelIDVisible: Bool { otherSelected }

    private var modelRow: some View {
        let list = choices
        var current = "Other…"
        if !typingModel {
            switch selection {
            case .choice(let id): current = list.first { $0.id == id }?.name ?? "Default"
            case .other(let id): current = id.isEmpty ? "Other…" : ModelChoices.displayName(for: id)
            }
        }
        let others = models.filter { name in !list.contains { $0.id == name } }
        return SettingsRow(title: "Model") {
            Menu {
                ForEach(list) { choice in
                    Button {
                        typingModel = false
                        assistant.settings.model = choice.id
                    } label: {
                        let title = "\(choice.name) · \(choice.note)"
                        if !typingModel && selection == .choice(choice.id) {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
                if !others.isEmpty {
                    Divider()
                    Menu("More models") {
                        ForEach(others, id: \.self) { name in
                            Button(name) {
                                typingModel = false
                                assistant.settings.model = name
                            }
                        }
                    }
                }
                if list.isEmpty, others.isEmpty { Text("No models listed") }
                Divider()
                Button("Other…") { typingModel = true }
            } label: {
                Text(current)
            }
            .controlSize(.regular)
            .fixedSize()
            .help("Choose from the models this provider offers, or type a model ID")
            .accessibilityLabel("Model, \(current)")
        }
    }

    private var effortRow: some View {
        SettingsRow(
            title: "Effort",
            detail: assistant.settings.commandIgnoresEffort ? "Your custom command ignores effort." : nil
        ) {
            Menu {
                Picker("Effort", selection: $assistant.settings.effort) {
                    Text("Default").tag("")
                    ForEach(kind.effortLevels, id: \.self) { Text(EffortMenu.name($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Text(assistant.settings.effort.isEmpty ? "Default" : EffortMenu.name(assistant.settings.effort))
            }
            .controlSize(.regular)
            .fixedSize()
            .help("How much the model thinks before it answers")
            .accessibilityLabel("Effort")
        }
    }

    private var modelIDRow: some View {
        SettingsRow(title: "Model ID") {
            TextField(
                "Model ID", text: $assistant.settings.model,
                prompt: Text(kind == .ollama || kind == .lmStudio ? "Model name" : "Model ID")
            )
            .labelsHidden()
            .font(Typeface.code)
            .settingsField()
            .frame(width: Self.fieldWidth)
            .accessibilityLabel("Model ID")
        }
    }

    // MARK: Language, test, advanced

    private var languageRow: some View {
        SettingsRow(title: "Answer in") {
            Menu {
                ForEach(languageOptions, id: \.name) { language in
                    Button {
                        assistant.settings.language = language.name
                    } label: {
                        let title =
                            language.native == language.name ? language.name : "\(language.native) — \(language.name)"
                        if language.name == assistant.settings.language {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                Text(assistant.settings.language)
            }
            .controlSize(.regular)
            .fixedSize()
            .accessibilityLabel("Answer in \(assistant.settings.language)")
        }
    }

    private var languageOptions: [(name: String, native: String)] {
        let current = assistant.settings.language
        let all = AISettings.languages
        return all.contains { $0.name == current } ? all : all + [(current, current)]
    }

    private var testRow: some View {
        SettingsRow(title: "Test", hasDetail: true) {
            testStatus.font(Typeface.meta).fixedSize(horizontal: false, vertical: true)
        } control: {
            NabButton("Test", action: runTest).disabled(test == .running)
        }
    }

    @ViewBuilder private var testStatus: some View {
        switch test {
        case .idle:
            Text("Not tested yet").foregroundStyle(Palette.inkTertiary)
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(Palette.inkSecondary)
            }
        case .passed(let detail):
            HStack(spacing: 6) {
                Image(systemName: "checkmark").font(Typeface.iconSmall)
                Text(detail)
            }
            .foregroundStyle(Palette.ok)
        case .failed(let detail):
            Text(detail).foregroundStyle(Palette.error).lineLimit(4).textSelection(.enabled)
        }
    }

    private var advancedHeader: some View {
        Button {
            withAnimation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion)) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: Space.m) {
                Text("Advanced").font(Typeface.body).foregroundStyle(Palette.ink)
                Spacer(minLength: Space.s)
                Image(systemName: "chevron.right").font(Typeface.iconMicro).foregroundStyle(Palette.inkSecondary)
                    .rotationEffect(.degrees(showAdvanced ? 90 : 0))
            }
            .settingsRowFrame()
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityLabel(showAdvanced ? "Hide advanced settings" : "Show advanced settings")
    }

    @ViewBuilder private var advanced: some View {
        if kind.isCLI {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Command").font(Typeface.body).foregroundStyle(Palette.ink)
                    Spacer()
                    if assistant.settings.command != kind.defaultCommand {
                        NabButton("Reset", kind: .ghost) { assistant.settings.command = kind.defaultCommand }
                    }
                }
                TextField("Command", text: $assistant.settings.command, axis: .vertical)
                    .labelsHidden()
                    .font(Typeface.code)
                    .lineLimit(2...6)
                    .settingsField()
                    .accessibilityLabel("Command")
                Text(
                    kind == .claudeCLI
                        ? "Runs in your login shell from an empty folder. The prompt arrives on stdin; $NAB_SYSTEM, $NAB_MODEL and $NAB_EFFORT carry the system prompt, model and effort."
                        : "Runs in your login shell. The system prompt and question arrive together on stdin; $NAB_MODEL and $NAB_EFFORT carry the model and effort."
                )
                .font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
            }
            .settingsRowFrame()
        } else if kind != .custom {
            serverRow
        } else {
            SettingsDetail(text: "Any server that speaks the OpenAI chat completions API.").settingsRowFrame()
        }
    }

    // MARK: Behavior

    /// Writes the typed key to the keychain; called on submit, blur, provider change, Test and disappear
    /// rather than per keystroke. Returns false when the keychain refused it.
    @discardableResult
    private func saveKey() -> Bool {
        guard keyKind.usesKey, key != assistant.key(for: keyKind) else { return true }
        do {
            try assistant.setKey(key, for: keyKind)
            keyError = nil
            return true
        } catch {
            keyError = error.localizedDescription
            NSLog("Nab: \(keyKind.title) key not saved: \(error.localizedDescription)")
            return false
        }
    }

    private func loadModels() async {
        models = []
        if kind == .claudeCLI {
            models = ClaudeModels.current
            return
        }
        guard !kind.isCLI else { return }
        let loading = kind
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        // The key being typed, before it is saved, so the list follows the field.
        let client = AIClient(settings: assistant.settings, apiKey: kind.usesKey ? key : nil)
        let list = (try? await client.models()) ?? kind.suggestedModels
        guard !Task.isCancelled, loading == kind else { return }
        models = list
        if let first = ModelChoices.initialModel(for: kind, current: assistant.settings.model, available: list) {
            assistant.settings.model = first
        }
    }

    /// Changes whenever something a status depends on changes.
    private var probeID: String {
        let probed = [ProviderKind.claudeCLI, .codexCLI, .ollama, .lmStudio]
        return probed.map {
            "\($0.rawValue)=\(assistant.settings.commands[$0] ?? "")|\(assistant.settings.baseURLs[$0] ?? "")"
        }
        .joined(separator: ";")
    }

    private func probe() async {
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        let settings = assistant.settings
        await withTaskGroup(of: (ProviderKind, ProviderStatus).self) { group in
            for provider in [ProviderKind.claudeCLI, .codexCLI] {
                let command = settings.commands[provider] ?? provider.defaultCommand
                group.addTask { (provider, .cli(found: await ProviderProbe.cliFound(command: command))) }
            }
            for provider in [ProviderKind.ollama, .lmStudio] {
                let url = settings.baseURLs[provider] ?? provider.defaultBaseURL
                group.addTask { (provider, .server(running: await ProviderProbe.serverRunning(baseURL: url))) }
            }
            for await (provider, status) in group { statuses[provider] = status }
        }
    }

    private func runTest() {
        // Clicking a button does not take focus from the key field, so the key is saved here.
        guard saveKey() else {
            test = .failed(keyError ?? "The key could not be saved.")
            return
        }
        let client = assistant.client
        if let problem = client.problem {
            test = .failed(problem)
            return
        }
        test = .running
        let start = ContinuousClock.now
        Task {
            do {
                var answer = ""
                let turns = [ChatMessage(role: .user, text: "Reply with the single word: ready")]
                for try await chunk in client.reply(context: "<nab_context sources=\"0\"></nab_context>", turns: turns)
                { answer += chunk }
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                test =
                    answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .failed("Connected, but the model sent an empty answer.")
                    : .passed(
                        "\(ModelChoices.displayName(for: client.modelLabel)) answered in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
                    )
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }
}
