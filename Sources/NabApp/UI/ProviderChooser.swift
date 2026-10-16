import NabAI
import SwiftUI

/// Picks the AI that answers: what is ready on this Mac comes first, then a model, then setup help for the rest.
/// The choice is written to `ai.settings` here; `onChosen` runs after it is saved. Used by the floating window when
/// a summary is asked for and no provider is set up, and by the welcome flow.
struct ProviderChooser: View {
    var onChosen: () -> Void
    /// When set, a "Later" button appears and calls it without saving anything.
    var onLater: (() -> Void)?
    /// A single line saying why the current provider cannot answer.
    var problem: String?

    @State private var assistant = Assistant.main
    @State private var ready: Set<ProviderKind> = []
    @State private var detected = false
    @State private var selected: ProviderKind?
    @State private var models: [String] = []
    @State private var model = ""

    init(onChosen: @escaping () -> Void, onLater: (() -> Void)? = nil, problem: String? = nil) {
        self.onChosen = onChosen
        self.onLater = onLater
        self.problem = problem
    }

    private static let offered: [ProviderKind] = ProviderKind.common + ProviderKind.more

    private var ordered: [ProviderKind] {
        Self.offered.filter { ready.contains($0) } + Self.offered.filter { !ready.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Choose an AI for summaries").font(Typeface.heading).foregroundStyle(Palette.ink)
                Text(problem ?? "Nab sends the transcript to the one you pick. You can change it in Settings.")
                    .font(Typeface.meta).foregroundStyle(problem == nil ? Palette.inkTertiary : Palette.error)
                    .lineLimit(1).truncationMode(.tail)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 150), spacing: Space.s)], alignment: .leading, spacing: Space.s
            ) {
                ForEach(ordered) { chip($0) }
            }
            if let kind = selected {
                detail(kind)
            }
            HStack(spacing: Space.s) {
                NabButton("Use \(selected?.shortTitle ?? "this")", kind: .primary, action: choose)
                    .disabled(!canChoose)
                if let onLater { NabButton("Later", kind: .ghost, action: onLater) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await detect() }
        .task(id: selected) { await loadModels() }
    }

    private func chip(_ kind: ProviderKind) -> some View {
        let on = kind == selected
        let isReady = ready.contains(kind)
        return Button {
            selected = kind
        } label: {
            HStack(spacing: 6) {
                Circle().fill(isReady ? Palette.ok : Palette.lineStrong).frame(width: 7, height: 7)
                Text(kind.shortTitle).font(Typeface.meta).foregroundStyle(Palette.ink).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 30)
            .background(on ? Palette.selected : Palette.control, in: .capsule)
            .overlay(Capsule().strokeBorder(on ? Palette.accentInk : Palette.controlBorder))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.shortTitle), \(detected ? (isReady ? "ready" : "not set up") : "checking")")
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    @ViewBuilder private func detail(_ kind: ProviderKind) -> some View {
        if kind.isCLI {
            CLIGuide(kind: kind) { state in
                if case .ready = state { ready.insert(kind) } else { ready.remove(kind) }
            }
        } else if kind.isLocalServer, !ready.contains(kind) {
            Text("\(kind.shortTitle) is not running. Start its local server, then pick it again.")
                .font(Typeface.meta).foregroundStyle(Palette.inkSecondary)
        } else if kind.usesKey, !ready.contains(kind) {
            Text(
                kind == .custom
                    ? "Add the server address in AI Settings." : "Add your \(kind.shortTitle) key in AI Settings."
            )
            .font(Typeface.meta).foregroundStyle(Palette.inkSecondary)
        }
        if ready.contains(kind), !kind.isCLI || !models.isEmpty {
            modelMenu(kind)
        }
    }

    private func modelMenu(_ kind: ProviderKind) -> some View {
        let list = ModelChoices.choices(for: kind, available: models)
        let all = list.map(\.id) + models.filter { id in !list.contains { $0.id == id } }
        return HStack(spacing: Space.s) {
            Text("Model").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
            MenuChip(title: model.isEmpty ? "Default" : ModelNames.display(model)) {
                ForEach(all, id: \.self) { id in
                    Button(id.isEmpty ? "Default" : ModelNames.display(id)) { model = id }
                }
            }
        }
    }

    private var canChoose: Bool {
        guard let kind = selected, ready.contains(kind) else { return false }
        return kind.isCLI || !model.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: Behavior

    private func choose() {
        guard let assistant, let kind = selected, canChoose else { return }
        var settings = assistant.settings
        settings.kind = kind
        settings.model = model.trimmingCharacters(in: .whitespaces)
        assistant.settings = settings
        // An unchanged value is not saved by the setter; the choice itself is what counts as "saved".
        settings.save()
        onChosen()
    }

    private func detect() async {
        guard let assistant else { return }
        let settings = assistant.settings
        await withTaskGroup(of: (ProviderKind, Bool).self) { group in
            for kind in [ProviderKind.claudeCLI, .codexCLI] {
                group.addTask {
                    if case .ready = await CLIStatus.check(kind) { return (kind, true) }
                    return (kind, false)
                }
            }
            for kind in [ProviderKind.ollama, .lmStudio] {
                let url = settings.baseURLs[kind] ?? kind.defaultBaseURL
                group.addTask { (kind, await ProviderProbe.serverRunning(baseURL: url)) }
            }
            for kind in ProviderKind.allCases where kind.usesKey && kind != .custom {
                let saved = !assistant.key(for: kind).isEmpty
                group.addTask { (kind, saved) }
            }
            for await (kind, isReady) in group {
                if isReady { ready.insert(kind) }
                if selected == nil, isReady, kind == settings.kind || !ready.contains(settings.kind) { selected = kind }
            }
        }
        detected = true
        if selected == nil { selected = settings.kind }
    }

    private func loadModels() async {
        models = []
        model = ""
        guard let assistant, let kind = selected, !kind.isCLI || kind == .claudeCLI else { return }
        if kind == .claudeCLI {
            models = ClaudeModels.current
            return
        }
        var settings = AISettings()
        settings.kind = kind
        settings.baseURLs = assistant.settings.baseURLs
        let client = AIClient(settings: settings, apiKey: kind.usesKey ? assistant.key(for: kind) : nil)
        let list = (try? await client.models()) ?? kind.suggestedModels
        guard !Task.isCancelled else { return }
        models = list
        model = ModelChoices.initialModel(for: kind, current: "", available: list) ?? list.first ?? ""
    }
}
