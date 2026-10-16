import NabAI
import NabCore
import SwiftUI

/// A chat about one or several videos: the sources on top, the thread and composer in the middle, and a
/// transcript drawer on the right that opens from a source card or a citation.
struct SessionPage: View {
    let ids: [String]
    let model: LibraryModel
    @State private var drawerID: String?
    /// The citation that opened the drawer; nil when a source card did.
    @State private var drawerFocus: LibraryModel.Focus?

    /// Videos in the order the chat numbers them.
    private var orderedIDs: [String] { model.assistant.conversation(ids)?.entryIDs ?? ids }

    private var entries: [Entry] { orderedIDs.compactMap { model.center.entry($0) } }

    /// Ready videos, which are the ones citations number.
    private var numbered: [Entry] { entries.filter { $0.capture != nil } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SourcesStrip(entries: entries, numbered: numbered, selected: drawerID, copy: model.copyContext) {
                    entry in
                    withAnimation(Motion.settle) {
                        drawerID = entry.id
                        drawerFocus = nil
                    }
                }
                ChatView(entryIDs: ids, model: model, activeCitation: activeCitation)
            }
            .frame(maxWidth: .infinity)
            if let drawerID, let entry = model.center.entry(drawerID) {
                TranscriptDrawer(
                    entry: entry, number: numbered.firstIndex { $0.id == drawerID }.map { $0 + 1 }, model: model,
                    focus: drawerFocus, onClose: closeDrawer
                )
                .id(drawerID)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipShape(.rect)
        .onChange(of: model.focus, initial: true) { _, focus in
            guard let focus, orderedIDs.contains(focus.entryID) else { return }
            withAnimation(Motion.settle) {
                drawerID = focus.entryID
                drawerFocus = focus
            }
        }
        .background {
            // Esc closes the drawer, unless the search palette is open and wants it first.
            if drawerID != nil, model.searchQuery == nil {
                Button("Close transcript", action: closeDrawer)
                    .keyboardShortcut(.escape, modifiers: [])
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }

    private func closeDrawer() {
        withAnimation(Motion.settle) {
            drawerID = nil
            drawerFocus = nil
        }
    }

    /// The citation that matches the passage lit in the drawer, so its chip in the thread is filled.
    private var activeCitation: Citation? {
        guard let focus = drawerFocus, drawerID == focus.entryID,
            let index = numbered.firstIndex(where: { $0.id == focus.entryID })
        else { return nil }
        return Citation(video: index + 1, seconds: focus.seconds)
    }
}

/// "Sources · 3": one card per video.
private struct SourcesStrip: View {
    let entries: [Entry]
    let numbered: [Entry]
    let selected: String?
    let copy: () -> Void
    let open: (Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack {
                Text("Sources · \(entries.count)").font(Typeface.label).foregroundStyle(Palette.inkTertiary)
                Spacer(minLength: Space.s)
                // ⇧⌘C is the library's copy-context shortcut on every page.
                NabButton("Copy all", shortcut: "⇧⌘C", kind: .ghost, action: copy)
                    .help("Copy the videos as a context pack for AI (⇧⌘C)")
            }
            GeometryReader { proxy in
                let width = max(
                    200, (proxy.size.width - CGFloat(entries.count - 1) * 10) / CGFloat(max(entries.count, 1)))
                ScrollView(.horizontal) {
                    HStack(spacing: 10) {
                        ForEach(entries) { entry in
                            SourceCard(
                                entry: entry, number: numbered.firstIndex { $0.id == entry.id }.map { $0 + 1 },
                                on: selected == entry.id
                            ) { open(entry) }
                            .frame(width: width)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .frame(height: 56)
        }
        .padding(.horizontal, Space.xl)
        .padding(.top, Space.s)
        .padding(.bottom, Space.l)
        .background(Palette.sunken.opacity(0.6))
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

private struct SourceCard: View {
    let entry: Entry
    let number: Int?
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Thumbnail(entry: entry, width: 72, badge: number.map { .index($0) })
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(Typeface.rowTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(detail).font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                on ? Palette.selected : (hovering ? Palette.hover : Palette.raised),
                in: .rect(cornerRadius: 12, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(
                    on ? Palette.accentInk : Palette.line)
            )
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .accessibilityLabel("Open the transcript of \(entry.title)")
        .help("Show the transcript")
    }

    private var detail: String {
        switch entry.phase {
        case .fetching: return "Fetching transcript…"
        case .failed: return entry.failure ?? "Could not be read"
        case .ready:
            let language = entry.capture?.transcript.map { $0.languageName ?? $0.languageCode } ?? "No captions"
            return [entry.durationText, language].filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }
}
