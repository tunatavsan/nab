import AppKit
import NabAI
import NabCore
import SwiftUI

/// Provider, model, key, language and a test, in one card.
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

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI").font(Typeface.title).foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                    Text("Used for summaries, session chats and the floating window.")
                        .font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                }
                providerList
                if kind.usesKey { keyField }
                if kind == .custom { serverField(title: "Server address") }
                modelSection
                languageRow
                Divider().overlay(Palette.line)
                testRow
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

    private var providerList: some View {
        VStack(spacing: 0) {
            ForEach(ProviderKind.common, id: \.self) { row($0) }
            moreRow
            if showMore || ProviderKind.more.contains(kind) {
                ForEach(ProviderKind.more, id: \.self) { row($0) }
            }
        }
        .clipShape(.rect(cornerRadius: Radius.thumb, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).strokeBorder(Palette.line))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Provider")
    }

    private func row(_ provider: ProviderKind) -> some View {
        let on = provider == kind
        let status = status(of: provider)
        return Button {
            assistant.settings.kind = provider
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(on ? Palette.accentInk : Palette.lineStrong, lineWidth: 1.5)
                    .frame(width: 16, height: 16)
                    .overlay { Circle().fill(on ? Palette.accentInk : .clear).frame(width: 6, height: 6) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.shortTitle).font(Typeface.rowTitle).foregroundStyle(Palette.ink)
                    Text(provider.blurb).font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(status.label)
                    .font(Typeface.meta)
                    .foregroundStyle(status.isPositive ? Palette.accentInk : Palette.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 170, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        }
        .buttonStyle(SettingsRowStyle(selected: on, tint: Palette.accentWash))
        .accessibilityLabel("\(provider.shortTitle), \(provider.blurb), \(status.label)")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private var moreRow: some View {
        let expanded = showMore || ProviderKind.more.contains(kind)
        return Button {
            withAnimation(Motion.resolved(Motion.settle, reduceMotion: reduceMotion)) { showMore.toggle() }
        } label: {
            HStack(spacing: 6) {
                Text("More providers").font(Typeface.button).foregroundStyle(Palette.inkSecondary)
                if !expanded {
                    Text("OpenRouter, LM Studio or your own server").font(Typeface.meta)
                        .foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(Typeface.iconMicro).foregroundStyle(Palette.inkSecondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.leading, 42)
            .padding(.trailing, 14)
            .frame(height: 38)
            .overlay(alignment: .bottom) { if expanded { Rectangle().fill(Palette.line).frame(height: 1) } }
        }
        .buttonStyle(SettingsRowStyle())
        .accessibilityLabel(expanded ? "Fewer providers" : "More providers")
    }

    private func status(of provider: ProviderKind) -> ProviderStatus {
        switch provider {
        case .anthropic, .openAI, .openRouter: .key(saved: !assistant.key(for: provider).isEmpty)
        case .custom: .address(assistant.settings.baseURLs[.custom] ?? "")
        default: statuses[provider] ?? .checking
        }
    }

    // MARK: Key and server

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API key").font(Typeface.label).foregroundStyle(Palette.inkTertiary)
            SecureField(
                "API key", text: $key, prompt: Text(kind == .custom ? "Optional" : "Paste your key")
            )
            .labelsHidden()
            .font(Typeface.body)
            .settingsField(focus: $keyFocused)
            .onSubmit { saveKey() }
            .accessibilityLabel("\(kind.shortTitle) API key")
            if let keyError {
                Text(keyError).font(Typeface.meta).foregroundStyle(Palette.error).textSelection(.enabled)
            } else {
                Text("Stored in your keychain").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
            }
        }
    }

    private func serverField(title: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(Typeface.label).foregroundStyle(Palette.inkTertiary)
            TextField(title, text: $assistant.settings.baseURL, prompt: Text(kind.defaultBaseURL))
                .labelsHidden()
                .font(Typeface.code)
                .settingsField()
                .accessibilityLabel(title)
        }
    }

    // MARK: Model

    private var choices: [ModelChoice] { ModelChoices.choices(for: kind, available: models) }

    private var selection: ModelChoices.Selection {
        ModelChoices.selection(model: assistant.settings.model, among: choices)
    }

    private var modelSection: some View {
        let list = choices
        var otherID = ""
        var otherSelected = typingModel
        if case .other(let id) = selection {
            otherID = id
            otherSelected = true
        }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Model").font(Typeface.label).foregroundStyle(Palette.inkTertiary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(list) { choice in
                    modelCard(
                        name: choice.name, note: choice.note,
                        on: !otherSelected && selection == .choice(choice.id)
                    ) {
                        typingModel = false
                        assistant.settings.model = choice.id
                    }
                }
                otherCard(selected: otherSelected, id: otherID)
            }
            if otherSelected {
                TextField(
                    "Model ID", text: $assistant.settings.model,
                    prompt: Text(kind == .ollama || kind == .lmStudio ? "Model name" : "Model ID")
                )
                .labelsHidden()
                .font(Typeface.code)
                .settingsField()
                .accessibilityLabel("Model ID")
            }
        }
    }

    private func modelCard(name: String, note: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { cardLabel(name: name, note: note, on: on) }
            .buttonStyle(SettingsRowStyle(selected: on, radius: Radius.thumb))
            .overlay(cardBorder(on: on))
            .accessibilityLabel("\(name), \(note)")
            .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func otherCard(selected: Bool, id: String) -> some View {
        Menu {
            ForEach(models, id: \.self) { name in
                Button(name) {
                    typingModel = false
                    assistant.settings.model = name
                }
            }
            if models.isEmpty { Text("No models listed") }
            Divider()
            Button("Type a model ID…") { typingModel = true }
        } label: {
            cardLabel(name: "Other…", note: id.isEmpty ? ModelChoices.otherNote(for: kind) : id, on: selected)
                .background(selected ? Palette.selected : .clear, in: .rect(cornerRadius: Radius.thumb))
                .contentShape(.rect(cornerRadius: Radius.thumb))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .overlay(cardBorder(on: selected))
        .help("Choose from the models this provider offers, or type a model ID")
        .accessibilityLabel("Other model")
    }

    private func cardLabel(name: String, note: String, on: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(name).font(Typeface.rowTitle).foregroundStyle(Palette.ink).lineLimit(1).truncationMode(.middle)
                Circle().fill(on ? Palette.accentInk : .clear).frame(width: 6, height: 6)
            }
            Text(note).font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func cardBorder(on: Bool) -> some View {
        RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous)
            .strokeBorder(on ? Palette.accent : Palette.line, lineWidth: on ? 1.5 : 1)
            .allowsHitTesting(false)
    }

    // MARK: Language, test, advanced

    private var languageRow: some View {
        HStack(spacing: 10) {
            Text("Answer in").font(Typeface.body).foregroundStyle(Palette.ink)
            Spacer()
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
                SettingsMenuLabel(title: assistant.settings.language)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
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
        HStack(spacing: 12) {
            NabButton("Test", action: runTest).disabled(test == .running)
            Group {
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
            .font(Typeface.meta)
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button {
                withAnimation(Motion.resolved(Motion.settle, reduceMotion: reduceMotion)) { showAdvanced.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text("Advanced").font(Typeface.meta)
                    Image(systemName: "chevron.right").font(Typeface.iconMicro)
                        .rotationEffect(.degrees(showAdvanced ? 90 : 0))
                }
                .foregroundStyle(Palette.inkSecondary)
                .padding(.vertical, 6)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showAdvanced ? "Hide advanced settings" : "Show advanced settings")
        }
    }

    @ViewBuilder private var advanced: some View {
        if kind.isCLI {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Command").font(Typeface.label).foregroundStyle(Palette.inkTertiary)
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
                        ? "Runs in your login shell from an empty folder. The prompt arrives on stdin; $NAB_SYSTEM and $NAB_MODEL carry the system prompt and model."
                        : "Runs in your login shell. The system prompt and question arrive together on stdin; $NAB_MODEL carries the model."
                )
                .font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
            }
        } else if kind != .custom {
            serverField(title: "Server address")
        } else {
            Text("Any server that speaks the OpenAI chat completions API.")
                .font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
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
