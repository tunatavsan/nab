import AppKit
import NabAI
import NabCore
import ServiceManagement
import SwiftUI

/// Every provider Nab can talk to, the prompts it sends, and the app's own switches.
struct SettingsView: View {
    @Bindable var assistant: Assistant
    @State private var key = ""
    /// The provider the key field belongs to. It trails `kind` until the typed key is saved.
    @State private var keyKind = ProviderKind.claudeCLI
    @State private var keyError: String?
    @FocusState private var keyFocused: Bool
    @State private var models: [String] = []
    @State private var test = TestState.idle
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    enum TestState: Equatable {
        case idle, running
        case passed(String)
        case failed(String)
    }

    private var kind: ProviderKind { assistant.settings.kind }

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $assistant.settings.kind) {
                    Section("On this Mac") {
                        ForEach([ProviderKind.claudeCLI, .codexCLI, .ollama, .lmStudio]) { Text($0.title).tag($0) }
                    }
                    Section("API") {
                        ForEach([ProviderKind.anthropic, .openAI, .openRouter, .custom]) { Text($0.title).tag($0) }
                    }
                }
                if kind.isCLI {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Command")
                            Spacer()
                            if assistant.settings.command != kind.defaultCommand {
                                Button("Reset") { assistant.settings.command = kind.defaultCommand }.buttonStyle(.link)
                            }
                        }
                        TextField("Command", text: $assistant.settings.command, axis: .vertical)
                            .labelsHidden()
                            .font(Typeface.code)
                            .lineLimit(2...6)
                    }
                } else {
                    TextField("Server", text: $assistant.settings.baseURL)
                    if kind.usesKey {
                        SecureField(
                            "API key", text: $key,
                            prompt: Text(kind == .custom ? "Optional" : "Stored in your keychain")
                        )
                        .focused($keyFocused)
                        .onSubmit { saveKey() }
                        if let keyError {
                            Text(keyError).font(Typeface.meta).foregroundStyle(Palette.error).textSelection(.enabled)
                        }
                    }
                }
                HStack {
                    TextField(
                        "Model", text: $assistant.settings.model,
                        prompt: Text(kind.isCLI ? "The CLI's default" : "Model ID"))
                    if !models.isEmpty {
                        Menu {
                            ForEach(models, id: \.self) { name in Button(name) { assistant.settings.model = name } }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Choose from the models this provider offers")
                    }
                }
                HStack(spacing: 10) {
                    Button("Test", action: runTest).disabled(test == .running)
                    switch test {
                    case .idle: EmptyView()
                    case .running: ProgressView().controlSize(.small)
                    case .passed(let detail):
                        Label(detail, systemImage: "checkmark.circle.fill").foregroundStyle(Palette.ok)
                    case .failed(let detail):
                        Label(detail, systemImage: "xmark.octagon.fill").foregroundStyle(Palette.error).lineLimit(4)
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("AI model")
            } footer: {
                Text(note).foregroundStyle(.secondary)
            }

            Section("Answers") {
                Picker("Language", selection: $assistant.settings.language) {
                    ForEach(AISettings.languages, id: \.name) { language in
                        Text(language.native == language.name ? language.name : "\(language.native) — \(language.name)")
                            .tag(language.name)
                    }
                    if !AISettings.languages.contains(where: { $0.name == assistant.settings.language }) {
                        Text(assistant.settings.language).tag(assistant.settings.language)
                    }
                }
                PromptEditor(
                    title: "System prompt", text: $assistant.settings.systemPrompt,
                    original: AISettings.defaultSystemPrompt,
                    note: "How the assistant behaves in every chat. {language} becomes the language above.")
                PromptEditor(
                    title: "Summarize asks", text: $assistant.settings.summaryPrompt,
                    original: AISettings.defaultSummaryPrompt,
                    note:
                        "Sent when you press Summarize; it becomes the first question of the chat. {language} becomes the language above."
                )
            }

            Section("General") {
                Toggle("Open at login", isOn: $openAtLogin)
                if let loginError { Text(loginError).foregroundStyle(Palette.error).font(.callout) }
                LabeledContent("Nab the front tab") { Text("⌃⌥N").font(Typeface.mono) }
                LabeledContent("Library and chats") {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            LibraryStore.defaultFolder.deletingLastPathComponent()
                        ])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
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
        }
        .onChange(of: keyFocused) { _, focused in
            if !focused { saveKey() }
        }
        .onDisappear { saveKey() }
        .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
        .task(id: "\(kind.rawValue)|\(assistant.settings.baseURL)|\(key.count)") { await loadModels() }
    }

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

    private var note: String {
        switch kind {
        case .claudeCLI:
            "Uses your Claude Code sign-in. Runs in your login shell from an empty folder; the prompt arrives on stdin, $NAB_SYSTEM and $NAB_MODEL carry the system prompt and model."
        case .codexCLI:
            "Uses your Codex sign-in (ChatGPT plan or API key). Runs in your login shell; the system prompt and question arrive together on stdin."
        case .anthropic:
            "Your key stays in the macOS keychain. Answers stream; recent Claude models fall back to another model server-side if a request is declined."
        case .openAI, .openRouter:
            "Your key stays in the macOS keychain. The model list loads once the key is set."
        case .ollama:
            "Start Ollama and pull a model; it appears in the list. Nothing leaves your Mac."
        case .lmStudio:
            "Start LM Studio's local server and load a model; it appears in the list. Nothing leaves your Mac."
        case .custom:
            "Any server that speaks the OpenAI chat completions API."
        }
    }

    private func loadModels() async {
        models = []
        if kind == .claudeCLI {
            models = kind.suggestedModels
            return
        }
        guard !kind.isCLI else { return }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        // The key being typed, before it is saved, so the list follows the field.
        let client = AIClient(settings: assistant.settings, apiKey: kind.usesKey ? key : nil)
        models = (try? await client.models()) ?? kind.suggestedModels
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
                        "\(client.modelLabel) answered in \(seconds.formatted(.number.precision(.fractionLength(1)))) s"
                    )
            } catch {
                test = .failed(error.localizedDescription)
            }
        }
    }

    private func setOpenAtLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct PromptEditor: View {
    let title: String
    @Binding var text: String
    let original: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if text != original { Button("Reset") { text = original }.buttonStyle(.link) }
            }
            TextEditor(text: $text)
                .font(Typeface.code)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 130)
                .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: Radius.thumb))
            Text(note).font(.callout).foregroundStyle(.secondary)
        }
    }
}
