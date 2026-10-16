import AppKit
import Carbon.HIToolbox
import NabAI
import NabCore
import SwiftUI

/// What the floating window is asking about, what the user typed, and the hooks its controller fills in.
@MainActor @Observable
final class AskModel {
    var scope = AskScope.session
    var sessionIDs: [String] = []
    var latestID: String?
    /// Videos handed in by a caller that are neither the session nor the latest one.
    var pinned: [String]?
    var draft = ""
    /// Set when the window came from a link or with a draft: no summary goes out until the user asks for one.
    var holdsSummary = false
    /// Bumped to move the cursor into the field.
    var focusRequest = 0
    /// Shows the provider chooser: a summary was asked for and the user never chose an AI.
    var choosing = false

    @ObservationIgnored var cite: (Citation) -> Void = { _ in }
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var ensureSummary: () -> Void = {}
    @ObservationIgnored var later: () -> Void = {}
    @ObservationIgnored var setHeight: (CGFloat) -> Void = { _ in }

    var ids: [String] { pinned ?? AskScope.ids(for: scope, session: sessionIDs, latest: latestID) }
    var showsPicker: Bool { pinned == nil && AskScope.offersChoice(session: sessionIDs, latest: latestID) }
}

enum AskMetrics {
    static let width: CGFloat = 700
    static let topOffset: CGFloat = 80
    static let answerMaxHeight: CGFloat = 360
}

/// A glass panel near the top centre of the screen to ask about the open session or the latest video without
/// opening the library. Streaming and saving stay in `Assistant`, so closing the window never stops an answer.
@MainActor
final class AskWindowController {
    private let panel: FloatingPanel
    private let model = AskModel()
    private let center: CaptureCenter
    private let assistant: Assistant
    private let openLibrary: ([String]) -> Void
    private let openVideo: (String, TimeInterval) -> Void
    private var monitors: [Any] = []

    /// A window on its way out counts as closed, so a click or shortcut during the animation opens it again.
    var isVisible: Bool { panel.isVisible && !panel.isClosing }

    init(
        center: CaptureCenter, assistant: Assistant, openLibrary: @escaping ([String]) -> Void,
        openVideo: @escaping (String, TimeInterval) -> Void
    ) {
        self.center = center
        self.assistant = assistant
        self.openLibrary = openLibrary
        self.openVideo = openVideo
        let model = model
        panel = FloatingPanel(size: NSSize(width: AskMetrics.width, height: 360), cornerRadius: Radius.ring) {
            AskView(model: model, assistant: assistant, center: center)
        }
        model.cite = { [weak self] in self?.open($0) }
        model.openSettings = { [weak self] in
            self?.close()
            assistant.openSettings()
        }
        model.ensureSummary = { [weak self] in self?.ensureSummary() }
        model.later = { [weak self] in
            self?.model.choosing = false
            self?.close()
        }
        model.setHeight = { [weak self] in self?.panel.setHeight($0) }
    }

    /// Opens the window. `ids` come from a caller that already knows what to ask about; without them it opens on
    /// the session, or on the latest video when the session is empty. A link can come from any web page, so with
    /// `holdsSummary` (and with a `draft`, which only fills the field) nothing is sent until the user asks.
    func show(ids: [String]? = nil, draft: String? = nil, holdsSummary: Bool = false) {
        refresh()
        if let ids {
            if ids == model.sessionIDs {
                model.scope = .session
                model.pinned = nil
            } else if ids == model.latestID.map({ [$0] }) {
                model.scope = .latest
                model.pinned = nil
            } else {
                model.pinned = ids
            }
        } else {
            model.pinned = nil
            model.scope = AskScope.initial(sessionIDs: model.sessionIDs)
        }
        model.draft = draft ?? ""
        model.holdsSummary = holdsSummary || draft != nil
        ensureSummary()
        guard !isVisible else {
            model.focusRequest += 1
            panel.makeKey()
            return
        }
        // Reopened while closing: `present` cancels the close animation, and the panel stays where it is.
        if !panel.isVisible { panel.placeTopCenter(offset: AskMetrics.topOffset) }
        panel.present()
        panel.makeKey()
        model.focusRequest += 1
        install()
    }

    func close() {
        removeMonitors()
        panel.dismiss()
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Follows a timecode from an answer: it plays through the router, or with ⌘ held opens the transcript in the
    /// library. The window stays where it is either way.
    func open(_ citation: Citation) {
        let ids = model.ids
        let order = assistant.conversation(ids)?.entryIDs ?? ids
        let videos = order.compactMap { center.entry($0) }.filter { $0.capture != nil }
        let index = (citation.video ?? 1) - 1
        guard videos.indices.contains(index) else { return }
        if NSEvent.modifierFlags.contains(.command) {
            openVideo(videos[index].id, citation.seconds)
        } else {
            PlaybackRouter.shared.play(entryID: videos[index].id, at: citation.seconds)
        }
    }

    private func refresh() {
        let ready = center.session.filter { $0.capture != nil }
        // Asking about the session marks it used, as the summary shortcut always did.
        model.sessionIDs = ready.isEmpty ? [] : center.sessionSummaryIDs()
        model.latestID = AskScope.latestID(
            in: center.entries.map { AskScope.Candidate(id: $0.id, addedAt: $0.addedAt, hasCapture: $0.capture != nil) }
        )
    }

    /// Summarizes unless the chat exists. When the user never chose an AI, or the chosen one cannot answer, the
    /// window shows the provider chooser instead; choosing starts the summary.
    private func ensureSummary() {
        let ids = model.ids
        guard !ids.isEmpty, !model.holdsSummary else { return }
        Task {
            await assistant.load(ids)
            guard assistant.conversation(ids)?.messages.isEmpty ?? true else { return }
            if assistant.needsProviderChoice {
                model.choosing = true
            } else {
                assistant.summarize(ids)
            }
        }
    }

    private func toggleScope() {
        guard model.showsPicker else { return }
        model.scope = model.scope.toggled(offered: true)
    }

    private func copyAnswer() {
        guard
            let text = assistant.conversation(model.ids)?.messages.last(where: { $0.role == .assistant && !$0.failed }),
            !text.text.isEmpty
        else { return }
        Pasteboard.copy(text.text)
    }

    private func openInLibrary() {
        let ids = model.ids
        close()
        if !ids.isEmpty { openLibrary(ids) }
    }

    // MARK: Events

    private func install() {
        removeMonitors()
        monitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, event.window !== self.panel, !MiniPlayer.shared.owns(event.window) else { return event }
                self.close()
                return event
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.panel else { return event }
                return self.handle(event) ? nil : event
            } as Any)
    }

    /// The panel never activates Nab, so the main menu's Edit shortcuts do not reach the field; they are routed
    /// here, along with the window's own keys.
    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = Int(event.keyCode)
        if flags.isEmpty {
            switch key {
            case kVK_Escape:
                close()
                return true
            case kVK_Tab:
                toggleScope()
                return true
            default: return false
            }
        }
        guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return false }
        switch (key, flags.contains(.shift)) {
        case (kVK_ANSI_O, false):
            openInLibrary()
            return true
        case (kVK_ANSI_C, false):
            if let field = panel.firstResponder as? NSTextView, field.selectedRange().length > 0 {
                return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
            }
            copyAnswer()
            return true
        case (kVK_ANSI_V, false): return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        case (kVK_ANSI_X, false): return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil)
        case (kVK_ANSI_A, false): return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
        case (kVK_ANSI_Z, false): return NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
        case (kVK_ANSI_Z, true): return NSApp.sendAction(Selector(("redo:")), to: nil, from: nil)
        default: return false
        }
    }
}

// MARK: View

struct AskView: View {
    @Bindable var model: AskModel
    let assistant: Assistant
    let center: CaptureCenter
    @FocusState private var composing: Bool
    @State private var answerHeight: CGFloat = 120

    var body: some View {
        let ids = model.ids
        let messages = assistant.conversation(ids)?.messages ?? []
        let busy = assistant.isStreaming(ids)
        VStack(spacing: 8) {
            header(ids)
            hairline
            answerCell(ids, messages: messages, busy: busy)
            hairline
            composer(ids, busy: busy)
            hints
        }
        .padding(8)
        .frame(width: AskMetrics.width)
        .ring()
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            model.setHeight($0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .environment(\.openURL, OpenURLAction(handler: cite))
        .task(id: ids) { await assistant.load(ids) }
        .onChange(of: model.scope) { model.ensureSummary() }
        .onChange(of: model.focusRequest, initial: true) { composing = true }
    }

    private func cite(_ url: URL) -> OpenURLAction.Result {
        guard let citation = Citation(url: url) else { return AnswerLinks.handle(url) }
        model.cite(citation)
        return .handled
    }

    private var hairline: some View {
        Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, 10)
    }

    // MARK: Header

    private func header(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if model.showsPicker {
                    SegmentedPicker(
                        [
                            (value: AskScope.session, title: "Session · \(model.sessionIDs.count)"),
                            (value: AskScope.latest, title: "Latest video"),
                        ], selection: $model.scope)
                    Keycap("⇥")
                }
                Spacer(minLength: 0)
                ModelMenu(assistant: assistant)
                EffortMenu(assistant: assistant)
            }
            let videos = ids.compactMap { center.entry($0) }
            if !videos.isEmpty {
                ChipFlow(spacing: 6) { ForEach(videos) { VideoChip(entry: $0) } }
            }
        }
        .padding(.init(top: 10, leading: 10, bottom: 12, trailing: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Answer

    private func answerCell(_ ids: [String], messages: [ChatMessage], busy: Bool) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                answerContent(ids, messages: messages, busy: busy)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) {
                $0.size.height
            } action: {
                answerHeight = $0
            }
        }
        .defaultScrollAnchor(.bottom)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .scrollIndicators(.automatic)
        .frame(height: min(answerHeight, AskMetrics.answerMaxHeight))
        .animation(Motion.settle, value: messages.count)
    }

    @ViewBuilder
    private func answerContent(_ ids: [String], messages: [ChatMessage], busy: Bool) -> some View {
        if ids.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Nothing to ask about yet").font(Typeface.heading).foregroundStyle(Palette.ink)
                Text("Nab a YouTube video, then ask about it here.")
                    .font(Typeface.body).foregroundStyle(Palette.inkTertiary)
            }
        } else if let answer = messages.last(where: { $0.role == .assistant }) {
            let question = messages.last { $0.role == .user }
            Text(
                AskScope.heading(
                    summary: question?.isSummaryRequest ?? false, question: question?.text, count: ids.count,
                    title: ids.count == 1 ? center.entry(ids[0])?.title : nil)
            )
            .font(Typeface.label)
            .tracking(0.3)
            .foregroundStyle(Palette.inkSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            MessageView(
                message: answer, isLast: answer.id == messages.last?.id,
                streaming: busy && answer.id == messages.last?.id,
                assistant: assistant, entryIDs: ids, showsActions: false)
        } else if model.choosing || assistant.client.problem != nil {
            ProviderChooser(
                onChosen: {
                    model.choosing = false
                    if !model.holdsSummary { model.ensureSummary() }
                }, onLater: model.later, problem: assistant.client.problem)
        } else if model.holdsSummary && !busy {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Ask a question below, or start with a summary.")
                    .font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                NabButton("Summarize", kind: .primary) {
                    model.holdsSummary = false
                    model.ensureSummary()
                }
            }
        } else {
            ThinkingDots(label: ids.count == 1 ? "Reading the transcript" : "Reading \(ids.count) transcripts")
        }
    }

    // MARK: Composer

    private func composer(_ ids: [String], busy: Bool) -> some View {
        let canSend = !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ids.isEmpty
        return HStack(spacing: 8) {
            TextField("Ask a follow-up", text: $model.draft)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .foregroundStyle(Palette.ink)
                .focused($composing)
                .onSubmit { send(ids) }
                .accessibilityLabel("Ask a follow-up")
            SendButton(stop: busy, enabled: busy || canSend, size: 32, neutralWhenIdle: true) {
                busy ? assistant.stop(ids) : send(ids)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 48)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.cell, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.cell, style: .continuous).strokeBorder(Palette.line))
    }

    private func send(_ ids: [String]) {
        guard !assistant.isStreaming(ids), !model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        if assistant.ask(model.draft, about: ids) { model.draft = "" }
    }

    // MARK: Hints

    private var hints: some View {
        HStack(spacing: 16) {
            hint("esc", "Close")
            hint("⇥", "Session or latest")
            hint("⌘O", "Open in library")
            hint("⌘C", "Copy answer")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Escape closes. Tab switches between the session and the latest video. Command O opens the library. Command C copies the answer."
        )
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(Typeface.mono).foregroundStyle(Palette.ink)
            Text(label).font(Typeface.meta).foregroundStyle(Palette.inkSecondary)
        }
    }
}

/// Left to right, wrapping to the next line when a chip does not fit.
private struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, arrange(subviews, width: bounds.width).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .unspecified)
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), frames)
    }
}

/// A video in scope: a 32×18 capsule thumbnail and its title.
private struct VideoChip: View {
    let entry: Entry

    var body: some View {
        HStack(spacing: 6) {
            Thumbnail(entry: entry, width: 32, radius: 9)
            Text(entry.title)
                .font(Typeface.meta)
                .foregroundStyle(Palette.inkSecondary)
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(Palette.raised, in: .capsule)
        .overlay(Capsule().strokeBorder(Palette.line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.title)
    }
}
