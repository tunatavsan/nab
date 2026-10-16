import AppKit
import NabAI
import NabCore
import SwiftUI

/// The conversation of a session page: a centred thread, the empty and problem states, and the composer that
/// floats over the bottom. Answers stream in and cite timecodes; a click on a citation opens the transcript
/// drawer at that moment (⌘-click opens the video instead).
struct ChatView: View {
    let entryIDs: [String]
    let model: LibraryModel
    /// The passage open in the transcript drawer, so its chip in the answer is filled.
    var activeCitation: Citation?
    @State private var draft = ""
    @State private var choosing = false
    @State private var selection: TextSelection?
    @FocusState private var composing: Bool

    private var assistant: Assistant { model.assistant }

    var body: some View {
        let messages = assistant.conversation(entryIDs)?.messages ?? []
        let busy = assistant.isStreaming(entryIDs)
        ZStack(alignment: .bottom) {
            ZStack {
                if messages.isEmpty {
                    intro.transition(.page)
                } else {
                    thread(messages, busy: busy).transition(.page)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            composer(busy: busy)
        }
        .environment(\.openURL, OpenURLAction(handler: cite))
        .task(id: entryIDs) { await assistant.load(entryIDs) }
        .onAppear { composing = true }
    }

    /// Videos in the order the model numbers them.
    private var ordered: [Entry] {
        let ids = assistant.conversation(entryIDs)?.entryIDs ?? entryIDs
        return ids.compactMap { model.center.entry($0) }.filter { $0.capture != nil }
    }

    // MARK: Thread

    private func thread(_ messages: [ChatMessage], busy: Bool) -> some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    threadHeader(messages, busy: busy)
                    ForEach(messages) { message in
                        MessageView(
                            message: message, isLast: message.id == messages.last?.id,
                            streaming: busy && message.id == messages.last?.id,
                            assistant: assistant, entryIDs: entryIDs, activeCitation: activeCitation,
                            askInWindow: model.askInWindow.map { open in { open(entryIDs) } }
                        )
                        .transition(.rise)
                    }
                }
                .frame(maxWidth: Space.chatWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Space.xl)
                .padding(.top, Space.xl)
                .padding(.bottom, 120)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .animation(Motion.settle, value: messages.count)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .scrollIndicators(.automatic)
        }
    }

    private func threadHeader(_ messages: [ChatMessage], busy: Bool) -> some View {
        HStack(alignment: .top, spacing: Space.m) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title(messages))
                    .font(Typeface.display)
                    .tracking(-0.4)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meta(messages)).font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
            }
            Spacer(minLength: Space.s)
            HStack(spacing: Space.xs) {
                NabButton("Copy chat", kind: .ghost, action: model.copyChat)
                    .help("Copy this conversation as text")
                NabButton("New chat", kind: .ghost) { assistant.clear(entryIDs) }
                    .disabled(busy)
                    .help("Start a new chat about these videos")
            }
        }
    }

    private func title(_ messages: [ChatMessage]) -> String {
        if entryIDs.count == 1, let video = ordered.first { return video.title }
        guard let first = messages.first(where: { $0.role == .user }) else { return "\(entryIDs.count) videos" }
        return first.isSummaryRequest ? "Summary of \(entryIDs.count) videos" : first.text
    }

    private func meta(_ messages: [ChatMessage]) -> String {
        let model = messages.last { $0.role == .assistant && !$0.failed }?.model ?? assistant.client.modelLabel
        let when = messages.first.map { ChatStamp.string(for: $0.date) }
        return [when, ModelNames.display(model)].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Empty

    private var intro: some View {
        let ready = !ordered.isEmpty
        let problem = assistant.client.problem
        return VStack(spacing: Space.l) {
            Image(systemName: "sparkles")
                .font(Typeface.iconHero)
                .foregroundStyle(Palette.accentInk)
                .frame(width: 48, height: 48)
                .background(Palette.accentWash, in: .circle)
            VStack(spacing: Space.xs) {
                Text(entryIDs.count == 1 ? "Ask about this video" : "Ask across \(entryIDs.count) videos")
                    .font(Typeface.title)
                    .foregroundStyle(Palette.ink)
                Text(
                    ready
                        ? "Answers come from the transcript and cite the moment they rest on."
                        : "Waiting for the transcript…"
                )
                .font(Typeface.meta)
                .foregroundStyle(Palette.inkTertiary)
                .multilineTextAlignment(.center)
            }
            if problem != nil || choosing {
                ProviderChooser(
                    onChosen: {
                        choosing = false
                        Task { await assistant.summarizeIfNew(entryIDs) }
                    }, problem: problem
                )
                .padding(.top, Space.s)
            } else {
                NabButton("Summarize", kind: .primary, size: .large) {
                    // A first summary asks which AI to use; `summarizeIfNew` loads the saved chat first.
                    if AISettings.isSaved { Task { await assistant.summarizeIfNew(entryIDs) } } else { choosing = true }
                }
                .disabled(!ready)
                .padding(.top, Space.xs)
                VStack(spacing: Space.xxs) {
                    ForEach(suggestions, id: \.self) { question in
                        SuggestionRow(text: question, enabled: ready) { assistant.ask(question, about: entryIDs) }
                    }
                }
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.bottom, 80)
        .frame(maxWidth: 460)
    }

    private var suggestions: [String] {
        entryIDs.count == 1
            ? [
                "What is the main argument, and what backs it up?",
                "List every tool, product and person mentioned.",
                "What should I do differently after watching this?",
                "Which parts can I skip?",
            ]
            : [
                "Where do these videos agree, and where do they disagree?",
                "Give each video three bullets.",
                "Which one should I watch first, and why?",
            ]
    }

    // MARK: Composer

    private func composer(busy: Bool) -> some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ordered.isEmpty
        return HStack(alignment: .bottom, spacing: 6) {
            TextField(
                entryIDs.count == 1 ? "Ask about this video" : "Ask about these videos", text: $draft,
                selection: $selection, axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(Typeface.body)
            .foregroundStyle(Palette.ink)
            .lineLimit(1...8)
            .focused($composing)
            .onSubmit(send)
            .onKeyPress(.return, phases: .down) { press in
                guard press.modifiers.contains(.option) || press.modifiers.contains(.shift) else { return .ignored }
                insertNewline()
                return .handled
            }
            .padding(.vertical, 9)
            .accessibilityLabel("Ask a question")
            ScopeMenu(ids: entryIDs, model: model)
                .padding(.bottom, 4)
            ModelMenu(assistant: assistant)
                .padding(.bottom, 4)
            EffortMenu(assistant: assistant)
                .padding(.bottom, 4)
            SendButton(stop: busy, enabled: busy || canSend) {
                busy ? assistant.stop(entryIDs) : send()
            }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.composer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.composer, style: .continuous)
                .strokeBorder(composing ? Palette.lineStrong : Palette.line)
        )
        .shadow(color: .black.opacity(0.28), radius: 20, y: 10)
        .animation(Motion.snap, value: composing)
        .frame(maxWidth: Space.chatWidth)
        .padding(.horizontal, Space.xl)
        .padding(.bottom, 18)
    }

    private func send() {
        guard !assistant.isStreaming(entryIDs), !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if assistant.ask(draft, about: entryIDs) { draft = "" }
    }

    /// ⌥Return: a line break at the cursor.
    private func insertNewline() {
        if let selection, case .selection(let range) = selection.indices {
            let offset = draft.distance(from: draft.startIndex, to: range.lowerBound)
            draft.replaceSubrange(range, with: "\n")
            self.selection = TextSelection(insertionPoint: draft.index(draft.startIndex, offsetBy: offset + 1))
        } else {
            draft += "\n"
        }
    }

    /// Links in an answer that is still being written arrive here. Once an answer is selectable, macOS sends its
    /// links to the system instead, which hands `nab-cite:` links back to the app delegate.
    private func cite(_ url: URL) -> OpenURLAction.Result {
        guard let citation = Citation(url: url) else { return .systemAction }
        model.open(citation)
        return .handled
    }
}

/// One turn. Questions sit on the right in a quiet bubble; answers run full width as Markdown.
struct MessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let streaming: Bool
    let assistant: Assistant
    let entryIDs: [String]
    var activeCitation: Citation?
    /// The model name, Copy and Answer again under a finished answer; the floating window leaves them out.
    var showsActions = true
    /// Adds "Ask in floating window" to the last answer's actions.
    var askInWindow: (() -> Void)?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The clock of an answer still writing itself in; nil once it is fully drawn, or for saved answers.
    private var clock: RevealClock? {
        guard message.role == .assistant, !message.failed,
            let clock = RevealClock.clock(for: message.id, streaming: streaming), !clock.finished
        else { return nil }
        return clock
    }

    var body: some View {
        switch message.role {
        case .user: question
        case .assistant: answer
        }
    }

    private var question: some View {
        HStack {
            Spacer(minLength: 48)
            Group {
                if message.isSummaryRequest {
                    Label {
                        Text("Summarize")
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(Palette.accentInk)
                    }
                    .font(Typeface.rowTitle)
                } else {
                    Text(message.text).font(Typeface.body).textSelection(.enabled)
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                Palette.selected,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: Radius.bubble, bottomLeadingRadius: Radius.bubble, bottomTrailingRadius: 4,
                    topTrailingRadius: Radius.bubble, style: .continuous)
            )
            .frame(maxWidth: 440, alignment: .trailing)
        }
    }

    private var answer: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            if message.failed {
                failure
            } else if message.text.isEmpty {
                ThinkingDots(
                    label: entryIDs.count == 1 ? "Reading the transcript" : "Reading \(entryIDs.count) transcripts")
            } else {
                MarkdownText(source: message.text, clock: reduceMotion ? nil : clock, active: activeCitation)
            }
            if showsActions, !streaming, !message.failed {
                HStack(spacing: Space.m) {
                    if let name = message.model {
                        Text(ModelNames.display(name)).font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                    }
                    CopyAction(text: message.text)
                    if isLast {
                        MessageAction(title: "Answer again", help: "Ask the last question again") {
                            assistant.regenerate(entryIDs)
                        }
                        if let askInWindow {
                            MessageAction(title: "Ask in floating window", help: "Continue in the floating AI window") {
                                askInWindow()
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .opacity(hovering || isLast ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Label {
                Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(Typeface.body)
            .foregroundStyle(Palette.error)
            if isLast {
                HStack(spacing: Space.s) {
                    NabButton("Try Again") { assistant.regenerate(entryIDs) }
                    NabButton("AI Settings", kind: .ghost, action: assistant.openSettings)
                }
            }
        }
    }
}

/// The model chip: models of the current provider, the provider itself, and a way into Settings.
/// Also meant for the floating AI window.
struct ModelMenu: View {
    @Bindable var assistant: Assistant

    var body: some View {
        let kind = assistant.settings.kind
        let choices = ModelNames.choices(for: kind)
        MenuChip(title: title) {
            if !choices.isEmpty {
                Picker("Model", selection: $assistant.settings.model) {
                    ForEach(choices, id: \.self) { Text(ModelNames.display($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
            }
            Menu("Provider") {
                Picker("Provider", selection: $assistant.settings.kind) {
                    ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Button("AI Settings…", action: assistant.openSettings)
        }
        .help("Model")
    }

    private var title: String {
        let settings = assistant.settings
        let model = settings.model.trimmingCharacters(in: .whitespaces)
        if model.isEmpty { return settings.kind.isCLI ? "Default model" : settings.kind.title }
        return ModelNames.display(model)
    }
}

/// Which videos a question is about: all of the session, or one of them.
private struct ScopeMenu: View {
    let ids: [String]
    let model: LibraryModel

    /// The videos to choose from: this page's, or the open session's when the page shows one of them.
    private var pool: [String] {
        if ids.count > 1 { return ids }
        let session = model.currentSessionIDs()
        return session.count > 1 && session.contains(ids.first ?? "") ? session : ids
    }

    var body: some View {
        let pool = pool
        if pool.count > 1 {
            MenuChip(title: ids.count > 1 ? "All \(ids.count) videos" : "This video") {
                Button {
                    model.go(.session(pool))
                } label: {
                    row("All \(pool.count) videos", on: ids.count > 1)
                }
                Divider()
                ForEach(Array(pool.enumerated()), id: \.element) { index, id in
                    Button {
                        model.go(.session([id]))
                    } label: {
                        row("\(index + 1) · \(model.center.entry(id)?.title ?? id)", on: ids == [id])
                    }
                }
            }
            .help("Which videos to ask about")
        }
    }

    @ViewBuilder private func row(_ title: String, on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

private struct SuggestionRow: View {
    let text: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Text(text).font(Typeface.body).multilineTextAlignment(.leading)
                Spacer(minLength: Space.s)
                Image(systemName: "arrow.up.right").font(Typeface.iconSmall)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -3)
            }
            .foregroundStyle(hovering ? Palette.ink : Palette.inkSecondary)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .disabled(!enabled)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }
}

struct SendButton: View {
    let stop: Bool
    let enabled: Bool
    var size: CGFloat = 36
    /// A plain control circle instead of dimmed lime when nothing can be sent.
    var neutralWhenIdle = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .font(stop ? Typeface.iconAction : Typeface.iconButton)
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(enabled ? Palette.onAccent : Palette.inkTertiary)
                .frame(width: size, height: size)
                .background(
                    enabled ? Palette.accent : (neutralWhenIdle ? Palette.control : Palette.accentSoft), in: .circle
                )
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .animation(Motion.snap, value: stop)
        .animation(Motion.snap, value: enabled)
        .accessibilityLabel(stop ? "Stop" : "Send")
        .help(stop ? "Stop" : "Send (Return) · new line: ⌥Return")
    }
}

/// A quiet text action under an answer.
private struct MessageAction: View {
    let title: String
    var symbol: String?
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(Typeface.iconSmall) }
                Text(title).font(Typeface.meta)
            }
            .foregroundStyle(hovering ? Palette.accentInk : Palette.inkTertiary)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.96))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .help(help)
        .accessibilityLabel(title)
    }
}

private struct CopyAction: View {
    let text: String
    @State private var copied = false

    var body: some View {
        MessageAction(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : nil, help: "Copy answer") {
            Pasteboard.copy(text)
            withAnimation(Motion.snap) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(Motion.settle) { copied = false }
            }
        }
    }
}

struct ThinkingDots: View {
    let label: String

    var body: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 5, height: 5)
                        .pulsing(low: 0.25, duration: 0.55, delay: Double(index) * 0.18)
                }
            }
            Text(label + "…").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
        }
        .frame(height: 22)
    }
}
