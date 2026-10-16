import AppKit
import Carbon.HIToolbox
import NabCore
import SwiftUI

/// One selectable line of the palette.
private enum PaletteRow: Identifiable {
    case video(VideoHit)
    case chat(ChatHit)
    case transcript(TranscriptHit)
    case nabLink(URL)
    case settings

    var id: String {
        switch self {
        case .video(let hit): "v:" + hit.id
        case .chat(let hit): "c:" + hit.id
        case .transcript(let hit): "t:" + hit.id
        case .nabLink: "a:nab"
        case .settings: "a:settings"
        }
    }
}

private struct PaletteGroup: Identifiable {
    let name: String
    let rows: [PaletteRow]
    var id: String { name }
}

/// The ⌘K palette: videos, chats, transcript lines and actions, all from the keyboard.
struct SearchPalette: View {
    let model: LibraryModel
    @FocusState private var focused: Bool
    @State private var selection = 0
    @State private var clipboardLink: URL?
    @State private var height: CGFloat = 800
    /// Found for `resultsQuery`; a search runs off the main thread once typing pauses.
    @State private var results = SearchResults()
    @State private var resultsQuery: String?
    @State private var escapeMonitor: Any?

    private var query: String { model.searchQuery ?? "" }
    private var center: CaptureCenter { model.center }

    /// What a new search has to start over for: the words, or a library that gained a video or a chat.
    private struct SearchKey: Equatable {
        let query: String
        let entries: Int
        let ready: Int
        let chats: Int
    }

    private var searchKey: SearchKey {
        SearchKey(
            query: query, entries: center.entries.count, ready: center.entries.count { $0.capture != nil },
            chats: model.assistant.conversations.count)
    }

    private var groups: [PaletteGroup] {
        let found = results
        var result: [PaletteGroup] = []
        if !found.videos.isEmpty {
            result.append(
                PaletteGroup(name: query.isEmpty ? "Recent videos" : "Videos", rows: found.videos.map(PaletteRow.video))
            )
        }
        if !found.chats.isEmpty {
            result.append(
                PaletteGroup(name: query.isEmpty ? "Recent chats" : "Chats", rows: found.chats.map(PaletteRow.chat)))
        }
        if !found.transcripts.isEmpty {
            let n = found.transcriptTotal
            result.append(
                PaletteGroup(
                    name: "In transcripts · \(n) line\(n == 1 ? "" : "s")",
                    rows: found.transcripts.map(PaletteRow.transcript)))
        }
        var actions: [PaletteRow] = []
        if let clipboardLink { actions.append(.nabLink(clipboardLink)) }
        let words = LibrarySearch.terms(query)
        if words.isEmpty || LibrarySearch.matches("Open Settings preferences", terms: words) {
            actions.append(.settings)
        }
        if !actions.isEmpty { result.append(PaletteGroup(name: "Actions", rows: actions)) }
        return result
    }

    var body: some View {
        let groups = groups
        let rows = groups.flatMap(\.rows)
        ZStack(alignment: .top) {
            Color(red: 8 / 255, green: 9 / 255, blue: 12 / 255).opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { model.searchQuery = nil }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                field
                Divider().overlay(Palette.line)
                if results.isEmpty, !query.isEmpty, resultsQuery == query {
                    noResults
                }
                if !rows.isEmpty {
                    list(groups, rows: rows)
                }
                footer
            }
            .frame(width: 660)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.lineStrong))
            .shadow(color: .black.opacity(0.4), radius: 28, y: 14)
            .padding(.top, 84)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Search")
            .onKeyPress(phases: [.down, .repeat]) { press in handle(press, rows: rows) }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.height
        } action: {
            height = $0
        }
        .onAppear {
            focused = true
            refreshClipboard()
            installEscape()
        }
        .onDisappear(perform: removeEscape)
        .task(id: searchKey) { await search() }
        .onChange(of: query) { selection = 0 }
        .onChange(of: results) { selection = 0 }
        .onExitCommand { model.searchQuery = nil }
    }

    // MARK: Pieces

    private var field: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium))
                .foregroundStyle(Palette.inkSecondary)
            TextField(
                "Search videos, chats and transcripts",
                // Once closed, the field still writes its last text back as it ends editing; that write would
                // reopen the palette, so it is dropped.
                text: Binding(get: { query }, set: { if model.searchQuery != nil { model.searchQuery = $0 } })
            )
            .textFieldStyle(.plain)
            .font(DMSans.font(18))
            .focused($focused)
            .accessibilityLabel("Search")
            Text("esc").font(Typeface.mono).foregroundStyle(Palette.inkTertiary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.controlBorder))
                .accessibilityHidden(true)
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(height: 58)
    }

    private var noResults: some View {
        VStack(spacing: 4) {
            Text("No results for “\(query)”").font(Typeface.rowTitle).foregroundStyle(Palette.inkSecondary)
            Text("Try another word, or a few words from what was said.")
                .font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func list(_ groups: [PaletteGroup], rows: [PaletteRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { group in
                        Text(group.name).font(Typeface.label).foregroundStyle(Palette.inkTertiary)
                            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                            .accessibilityAddTraits(.isHeader)
                        ForEach(group.rows) { row in
                            let index = rows.firstIndex { $0.id == row.id } ?? 0
                            PaletteRowView(
                                row: row, model: model, selected: index == selection,
                                terms: LibrarySearch.terms(query)
                            ) { open(row) }
                            .id(row.id)
                            .onHover { if $0 { selection = index } }
                        }
                    }
                }
                .padding(.horizontal, 8).padding(.top, 2).padding(.bottom, 8)
            }
            .frame(maxHeight: min(440, max(160, height - 84 - 58 - 36 - 40)))
            .scrollBounceBehavior(.basedOnSize)
            .onChange(of: selection) {
                if rows.indices.contains(selection) { proxy.scrollTo(rows[selection].id) }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            hint("↑↓", "Move")
            hint("↵", "Open")
            hint("⌘↵", "Ask AI about the selection")
            hint("⌘C", "Copy context")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .overlay(alignment: .top) { Divider().overlay(Palette.line) }
        .accessibilityHidden(true)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(Typeface.mono).foregroundStyle(Palette.inkSecondary)
            Text(label).font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
        }
    }

    // MARK: Search

    /// Waits for a pause in typing, then searches value copies of the library off the main thread. A newer
    /// keystroke cancels this task, which stops the scan and drops its answer.
    private func search() async {
        let query = query
        if resultsQuery != nil, !query.isEmpty { try? await Task.sleep(for: .milliseconds(80)) }
        guard !Task.isCancelled else { return }
        let entries = center.entries
        let previews = model.assistant.previews(entries: entries)
        let work = Task.detached(priority: .userInitiated) {
            LibrarySearch.search(query, entries: entries, previews: previews)
        }
        let found = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard !Task.isCancelled else { return }
        results = found
        resultsQuery = query
    }

    // MARK: Actions

    private func handle(_ press: KeyPress, rows: [PaletteRow]) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let current = min(selection, rows.count - 1)
        switch press.key {
        case .downArrow:
            selection = min(current + 1, rows.count - 1)
            return .handled
        case .upArrow:
            selection = max(current - 1, 0)
            return .handled
        case .return:
            if press.modifiers.contains(.command) { ask(rows[current]) } else { open(rows[current]) }
            return .handled
        default:
            if press.modifiers == .command, press.characters == "c", copy(rows[current]) { return .handled }
            return .ignored
        }
    }

    private func entryIDs(_ row: PaletteRow) -> [String] {
        switch row {
        case .video(let hit): [hit.entryID]
        case .chat(let hit): hit.chat.entryIDs
        case .transcript(let hit): [hit.entryID]
        case .nabLink, .settings: []
        }
    }

    private func open(_ row: PaletteRow) {
        switch row {
        case .video(let hit):
            if let entry = center.entry(hit.entryID) { model.open(entry) }
        case .chat(let hit):
            model.searchQuery = nil
            model.go(.session(hit.chat.entryIDs))
        case .transcript(let hit):
            if let entry = center.entry(hit.entryID) { model.open(entry, at: hit.seconds) }
        case .nabLink(let url):
            model.searchQuery = nil
            center.add(linksIn: url.absoluteString)
        case .settings:
            model.searchQuery = nil
            model.go(.settings)
        }
    }

    private func ask(_ row: PaletteRow) {
        let ids = entryIDs(row)
        if ids.isEmpty { open(row) } else { model.ask(about: ids) }
    }

    /// Copies the selection's context; false when the row has none, so ⌘C still copies the field's text.
    private func copy(_ row: PaletteRow) -> Bool {
        let ids = entryIDs(row)
        guard ids.contains(where: { center.entry($0)?.capture != nil }) else { return false }
        model.copyContext(of: ids)
        model.searchQuery = nil
        return true
    }

    /// An empty search field keeps Esc to itself, so neither `onExitCommand` nor `onKeyPress` sees it; the palette
    /// closes on Esc from a monitor that runs before the field.
    private func installEscape() {
        removeEscape()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Int(event.keyCode) == kVK_Escape, event.window?.identifier == LibraryWindowController.windowID else {
                return event
            }
            MainActor.assumeIsolated { model.searchQuery = nil }
            return nil
        }
    }

    private func removeEscape() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    private func refreshClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        clipboardLink = center.registry.links(in: text).first
    }
}

private struct PaletteRowView: View {
    let row: PaletteRow
    let model: LibraryModel
    let selected: Bool
    let terms: [String]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                lead
                VStack(alignment: .leading, spacing: 2) {
                    Text(styled(primary)).font(Typeface.body).lineLimit(1)
                        .foregroundStyle(Palette.ink.opacity(0.85))
                    Text(secondary).font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if selected {
                    Text("↵").font(Typeface.mono).foregroundStyle(Palette.inkTertiary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(selected ? Palette.selected : .clear, in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(.rect(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var lead: some View {
        switch row {
        case .video(let hit):
            if let entry = model.center.entry(hit.entryID) {
                Thumbnail(entry: entry, width: 48, radius: Radius.chip)
            }
        case .chat:
            iconBox("sparkle")
        case .transcript(let hit):
            Text(Timecode.string(hit.seconds)).font(Typeface.chip).foregroundStyle(Palette.accentInk)
                .frame(width: 48).padding(.vertical, 2)
                .background(Palette.accentWash, in: .rect(cornerRadius: Radius.chip, style: .continuous))
        case .nabLink: iconBox("plus")
        case .settings: iconBox("gearshape")
        }
    }

    private func iconBox(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.inkSecondary)
            .frame(width: 48, height: 27)
            .background(Palette.control, in: .rect(cornerRadius: Radius.chip, style: .continuous))
    }

    private var primary: [HighlightPart] {
        switch row {
        case .video(let hit): hit.title
        case .chat(let hit): hit.title
        case .transcript(let hit): hit.snippet
        case .nabLink: [HighlightPart(text: "Nab the link on your clipboard", isMatch: false)]
        case .settings: [HighlightPart(text: "Open Settings", isMatch: false)]
        }
    }

    private var secondary: String {
        switch row {
        case .video(let hit):
            guard let entry = model.center.entry(hit.entryID) else { return "" }
            var parts: [String] = []
            if let author = hit.author { parts.append(author) }
            if !entry.durationText.isEmpty { parts.append(entry.durationText) }
            parts.append(
                model.center.session.contains { $0.id == entry.id }
                    ? "this session" : entry.addedAt.formatted(.dateTime.month(.abbreviated).day()))
            return parts.joined(separator: " · ")
        case .chat(let hit):
            let n = hit.chat.entryIDs.count
            return "Chat · \(n) video\(n == 1 ? "" : "s") · "
                + hit.chat.updatedAt.formatted(date: .omitted, time: .shortened)
        case .transcript(let hit): return hit.videoTitle
        case .nabLink(let url): return (url.host() ?? "") + url.path() + (url.query().map { "?" + $0 } ?? "")
        case .settings: return "Choose the AI model, language and shortcuts"
        }
    }

    private var label: String {
        switch row {
        case .video(let hit): hit.title.map(\.text).joined()
        case .chat(let hit): "Chat: " + hit.title.map(\.text).joined()
        case .transcript(let hit):
            "\(Timecode.string(hit.seconds)) \(hit.snippet.map(\.text).joined()), \(hit.videoTitle)"
        case .nabLink: "Nab the link on your clipboard"
        case .settings: "Open Settings"
        }
    }

    private func styled(_ parts: [HighlightPart]) -> AttributedString {
        var result = AttributedString()
        for part in parts {
            var piece = AttributedString(part.text)
            if part.isMatch {
                piece.foregroundColor = Palette.accentInk
                piece.font = Typeface.rowTitle
            }
            result += piece
        }
        return result
    }
}
