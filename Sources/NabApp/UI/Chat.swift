import AppKit
import NabAI
import NabCore
import SwiftUI

/// The chat beside the reader. Answers stream in, cite timecodes, and a click on a timecode scrolls
/// the transcript to the passage it rests on (⌘-click opens the video there instead).
struct ChatView: View {
    let entryIDs: [String]
    let model: LibraryModel
    @State private var draft = ""
    @FocusState private var composing: Bool

    private var assistant: Assistant { model.assistant }

    var body: some View {
        let messages = assistant.conversation(entryIDs)?.messages ?? []
        let busy = assistant.isStreaming(entryIDs)
        VStack(spacing: 0) {
            header(hasMessages: !messages.isEmpty, busy: busy)
            ZStack {
                if messages.isEmpty {
                    intro.transition(.opacity)
                } else {
                    transcript(messages, busy: busy).transition(.opacity)
                }
            }
            .frame(maxHeight: .infinity)
            composer(busy: busy)
        }
        .environment(\.openURL, OpenURLAction(handler: cite))
        .animation(Motion.settle, value: messages.isEmpty)
        .task(id: entryIDs) { await assistant.load(entryIDs) }
        .onAppear { composing = true }
    }

    /// Videos in the order the model numbers them.
    private var ordered: [Entry] {
        let ids = assistant.conversation(entryIDs)?.entryIDs ?? entryIDs
        return ids.compactMap { model.center.entry($0) }.filter { $0.capture != nil }
    }

    // MARK: Header

    private func header(hasMessages: Bool, busy: Bool) -> some View {
        HStack(spacing: Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Chat").font(Typeface.rowTitle).foregroundStyle(Palette.ink)
                Text(entryIDs.count == 1 ? "This video" : "\(entryIDs.count) videos")
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer(minLength: Space.s)
            ProviderMenu(assistant: assistant)
            if hasMessages {
                IconButton(symbol: "square.and.pencil", help: "New chat") { assistant.clear(entryIDs) }
                    .disabled(busy)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .animation(Motion.snap, value: hasMessages)
    }

    // MARK: Empty

    private var intro: some View {
        let ready = !ordered.isEmpty
        let problem = assistant.client.problem
        return VStack(spacing: Space.l) {
            Image(systemName: "sparkles")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.accent)
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
            if let problem {
                VStack(spacing: Space.s) {
                    Text(problem).font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                    PrimaryButton(title: "Open AI Settings", symbol: "gearshape", action: assistant.openSettings)
                        .frame(maxWidth: 220)
                }
                .padding(.top, Space.s)
            } else {
                PrimaryButton(title: "Summarize", symbol: "sparkles", enabled: ready) { assistant.summarize(entryIDs) }
                    .frame(maxWidth: 220)
                    .padding(.top, Space.xs)
                VStack(spacing: Space.xxs) {
                    ForEach(suggestions, id: \.self) { question in
                        SuggestionRow(text: question, enabled: ready) { assistant.ask(question, about: entryIDs) }
                    }
                }
            }
        }
        .padding(.horizontal, Space.xl)
        .frame(maxWidth: 420)
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

    // MARK: Messages

    private func transcript(_ messages: [ChatMessage], busy: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                ForEach(messages) { message in
                    MessageView(
                        message: message, isLast: message.id == messages.last?.id,
                        streaming: busy && message.id == messages.last?.id,
                        assistant: assistant, entryIDs: entryIDs
                    )
                    .transition(.rise)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .animation(Motion.settle, value: messages.count)
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollIndicators(.automatic)
    }

    // MARK: Composer

    private func composer(busy: Bool) -> some View {
        let canSend = !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ordered.isEmpty
        return HStack(alignment: .bottom, spacing: Space.s) {
            TextField(
                entryIDs.count == 1 ? "Ask about this video" : "Ask about these videos", text: $draft, axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(Typeface.body)
            .foregroundStyle(Palette.ink)
            .lineLimit(1...8)
            .focused($composing)
            .onSubmit(send)
            .padding(.vertical, 8)
            SendButton(stop: busy, enabled: busy || canSend) {
                busy ? assistant.stop(entryIDs) : send()
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.composer, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.composer, style: .continuous).strokeBorder(
                composing ? Palette.accent.opacity(0.5) : Palette.hairline)
        )
        .animation(Motion.snap, value: composing)
        .padding(Space.m)
    }

    private func send() {
        guard !assistant.isStreaming(entryIDs), !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        assistant.ask(draft, about: entryIDs)
        draft = ""
    }

    /// Links in an answer that is still being written arrive here. Once an answer is selectable, macOS sends its
    /// links to the system instead, which hands `nab-cite:` links back to the app delegate.
    private func cite(_ url: URL) -> OpenURLAction.Result {
        guard let citation = Citation(url: url) else { return .systemAction }
        model.open(citation)
        return .handled
    }
}

/// One turn. Questions sit right in an ember wash; answers run full width as Markdown.
private struct MessageView: View {
    let message: ChatMessage
    let isLast: Bool
    let streaming: Bool
    let assistant: Assistant
    let entryIDs: [String]
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
                    Label("Summarize", systemImage: "sparkles").font(Typeface.rowTitle)
                } else {
                    Text(message.text).font(Typeface.body).textSelection(.enabled)
                }
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Palette.accentWash, in: .rect(cornerRadius: Radius.bubble, style: .continuous))
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
                MarkdownText(source: message.text, clock: reduceMotion ? nil : clock)
            }
            if !streaming, !message.failed {
                HStack(spacing: Space.xs) {
                    Text(message.model ?? "").font(Typeface.mono).foregroundStyle(Palette.inkTertiary)
                    Spacer()
                    CopyIconButton(text: message.text)
                    if isLast {
                        IconButton(symbol: "arrow.clockwise", help: "Answer again") { assistant.regenerate(entryIDs) }
                    }
                }
                .opacity(hovering || isLast ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Label {
                Text(message.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .font(Typeface.body)
            .foregroundStyle(Palette.accent)
            if isLast {
                HStack(spacing: Space.s) {
                    Button("Try Again", systemImage: "arrow.clockwise") { assistant.regenerate(entryIDs) }
                    Button("AI Settings", systemImage: "gearshape", action: assistant.openSettings)
                }
                .buttonStyle(.glass)
                .font(Typeface.rowTitle)
            }
        }
    }
}

/// Switch provider without opening Settings.
private struct ProviderMenu: View {
    @Bindable var assistant: Assistant

    var body: some View {
        Menu {
            Picker("Provider", selection: $assistant.settings.kind) {
                ForEach(ProviderKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("AI Settings…", action: assistant.openSettings)
        } label: {
            HStack(spacing: 4) {
                Text(assistant.client.modelLabel).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
            .font(Typeface.label)
            .foregroundStyle(Palette.inkSecondary)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model")
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
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .bold))
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

private struct SendButton: View {
    let stop: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: stop ? "stop.fill" : "arrow.up")
                .font(.system(size: stop ? 10 : 13, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(stop ? Palette.ink : Palette.onAccent)
                .frame(width: 28, height: 28)
                .background(stop ? Palette.pressed : Palette.accent.opacity(enabled ? 1 : 0.35), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .padding(.bottom, 2)
        .animation(Motion.snap, value: stop)
        .help(stop ? "Stop" : "Send (Return) · new line: ⌥Return")
    }
}

private struct CopyIconButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        IconButton(symbol: copied ? "checkmark" : "doc.on.doc", help: "Copy answer") {
            Pasteboard.copy(text)
            withAnimation(Motion.snap) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(Motion.settle) { copied = false }
            }
        }
    }
}

private struct ThinkingDots: View {
    let label: String

    var body: some View {
        HStack(spacing: Space.s) {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 5, height: 5)
                        .phaseAnimator([0.25, 1.0]) { dot, value in
                            dot.opacity(value)
                        } animation: { _ in
                            .easeInOut(duration: 0.55).delay(Double(index) * 0.18)
                        }
                }
            }
            Text(label + "…").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
        }
        .frame(height: 22)
    }
}
