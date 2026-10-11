import AppKit
import NabCore
import SwiftUI

/// The library window. Nab is a menu bar app; while this window is open it also takes a Dock icon
/// and a place in ⌘Tab, and gives them back when the window closes.
@MainActor
final class LibraryWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let model: LibraryModel

    init(center: CaptureCenter, assistant: Assistant) {
        model = LibraryModel(center: center, assistant: assistant)
        let host = NSHostingController(rootView: LibraryView(model: model))
        host.sceneBridgingOptions = [.toolbars, .title]
        window = NSWindow(contentViewController: host)
        super.init()
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Nab"
        window.setContentSize(NSSize(width: 1240, height: 760))
        window.contentMinSize = NSSize(width: 820, height: 480)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NabLibrary")
        window.delegate = self
        if !window.setFrameUsingName("NabLibrary") { window.center() }
    }

    /// Brings the window forward; `ids` replace the selection, `chat` opens the chat beside it.
    func show(select ids: [String], chat: Bool = false) {
        if !ids.isEmpty { model.selection = Set(ids) }
        if chat { model.showChat = true }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showSettings() {
        model.page = .settings
        show(select: [])
    }

    func windowWillClose(_ notification: Notification) {
        DockPresence.update(closing: window)
    }
}

@MainActor
enum DockPresence {
    /// Nab keeps a Dock icon only while one of its windows is open.
    static func update(closing: NSWindow? = nil) {
        let open = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled)
        }
        NSApp.setActivationPolicy(open ? .regular : .accessory)
    }
}

@MainActor
@Observable
final class LibraryModel {
    let center: CaptureCenter
    let assistant: Assistant
    var selection: Set<String> = [] {
        didSet { if !selection.isEmpty, selection != oldValue { page = .library } }
    }
    var query = ""
    /// Settings live in this window, as a page beside the library.
    enum Page { case library, settings }
    var page = Page.library
    var showChat = UserDefaults.standard.bool(forKey: "library.showChat") {
        didSet { UserDefaults.standard.set(showChat, forKey: "library.showChat") }
    }

    /// A transcript moment to scroll to; `token` makes a repeated click scroll again.
    struct Focus: Equatable {
        let entryID: String
        let seconds: TimeInterval
        let token = UUID()
    }
    var focus: Focus?

    init(center: CaptureCenter, assistant: Assistant) {
        self.center = center
        self.assistant = assistant
    }

    /// The selection the chat is about, in library order.
    var chatIDs: [String] { selected.map(\.id) }

    func jump(to entryID: String, at seconds: TimeInterval) { focus = Focus(entryID: entryID, seconds: seconds) }

    /// Opens the chat and summarizes the selection unless that chat already started.
    func summarize() {
        showChat = true
        let ids = chatIDs
        Task { await assistant.summarizeIfNew(ids) }
    }

    var visible: [Entry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return center.entries }
        return center.entries.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || ($0.capture?.author?.localizedCaseInsensitiveContains(q) ?? false)
        }
    }

    var selected: [Entry] { center.entries.filter { selection.contains($0.id) } }
    var selectedCaptures: [Capture] { selected.compactMap(\.capture) }

    func pack() -> String { ContextPack.render(selectedCaptures) }

    func export() { Exporter.save(selectedCaptures) }
}

struct LibraryView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.visible) { entry in
                    EntryRow(entry: entry)
                        .tag(entry.id)
                        .contextMenu {
                            if entry.phase == .failed { Button("Try Again") { model.center.retry(entry.id) } }
                            Button("Open in Browser") { NSWorkspace.shared.open(entry.url) }
                            Button("Copy Link") { Pasteboard.copy(entry.url.absoluteString) }
                            Divider()
                            Button("Remove from Library", role: .destructive) {
                                let ids = model.selection.contains(entry.id) ? model.selection : [entry.id]
                                model.center.remove(ids)
                                model.selection.subtract(ids)
                            }
                        }
                }
            }
            .animation(Motion.settle, value: model.visible.map(\.id))
            .searchable(text: $model.query, placement: .sidebar, prompt: "Filter")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsRow(active: model.page == .settings) { model.page = .settings }
                    .padding(.horizontal, Space.s)
                    .padding(.bottom, Space.s)
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 420)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
        }
        .inspector(
            isPresented: Binding(get: { model.showChat && model.page == .library }, set: { model.showChat = $0 })
        ) {
            chat.inspectorColumnWidth(min: 320, ideal: 420, max: 640)
        }
        .navigationTitle(model.page == .settings ? "Settings" : "Nab")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("Paste Links", systemImage: "link.badge.plus", action: model.center.pasteLinks)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Add every YouTube link on the clipboard (⇧⌘V)")
                Button("Copy Context", systemImage: "doc.on.doc") { Pasteboard.copy(model.pack()) }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.selectedCaptures.isEmpty)
                    .help("Copy the selection as an AI-ready context pack (⇧⌘C)")
                Button("Chat", systemImage: "bubble.left.and.text.bubble.right") {
                    if model.page == .settings {
                        model.page = .library
                        model.showChat = true
                    } else {
                        model.showChat.toggle()
                    }
                }
                .keyboardShortcut("j", modifiers: .command)
                .help("Show or hide the chat (⌘J)")
            }
        }
    }

    @ViewBuilder private var chat: some View {
        let ids = model.chatIDs
        if ids.isEmpty {
            Text("Select a video to ask about it.")
                .font(Typeface.meta)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChatView(entryIDs: ids, model: model)
                .id(Conversation.id(for: ids))
        }
    }

    @ViewBuilder private var detail: some View {
        let selected = model.selected
        ZStack {
            if model.page == .settings {
                SettingsView(assistant: model.assistant)
                    .transition(.opacity)
            } else if selected.count == 1, let entry = selected.first {
                ReaderView(entry: entry, model: model)
                    .id(entry.id)
                    .transition(.opacity)
            } else if selected.count > 1 {
                PackView(entries: selected, model: model)
                    .transition(.opacity)
            } else {
                EmptyLibraryView(isEmpty: model.center.entries.isEmpty)
                    .transition(.opacity)
            }
        }
        .animation(Motion.settle, value: selected.map(\.id))
        .animation(Motion.settle, value: model.page)
    }
}

/// The sidebar's last row: Settings, a page in this window rather than a window of its own.
private struct SettingsRow: View {
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .rotationEffect(.degrees(active ? 60 : 0))
                Text("Settings").font(Typeface.rowTitle)
                Spacer()
                Text("⌘,").font(Typeface.mono).foregroundStyle(Palette.inkTertiary).opacity(hovering ? 1 : 0)
            }
            .foregroundStyle(active ? Palette.accent : (hovering ? Palette.ink : Palette.inkSecondary))
            .padding(.horizontal, Space.m)
            .frame(height: 36)
            .background(
                active ? Palette.accentWash : (hovering ? Palette.hover : .clear),
                in: .rect(cornerRadius: Radius.row, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .keyboardShortcut(",", modifiers: .command)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .animation(Motion.lift, value: active)
    }
}

private struct EntryRow: View {
    let entry: Entry
    var body: some View {
        HStack(spacing: Space.m) {
            Thumb(entry: entry, width: 80)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(entry.title)
                    .font(Typeface.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                HStack(spacing: Space.xs) {
                    if entry.capture?.aiSummary != nil {
                        Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold)).foregroundStyle(
                            Palette.accent
                        )
                        .help("Summarized")
                    }
                    Text(entry.metaLine)
                        .font(Typeface.meta)
                        .foregroundStyle(entry.phase == .failed ? Palette.accent : Palette.inkTertiary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .animation(Motion.snap, value: entry.phase)
    }
}

private struct EmptyLibraryView: View {
    let isEmpty: Bool
    var body: some View {
        VStack(spacing: Space.m) {
            Text(isEmpty ? "Nothing nabbed yet." : "Select a video.")
                .font(Typeface.display)
                .foregroundStyle(Palette.inkSecondary)
            if isEmpty {
                HStack(spacing: Space.s) {
                    Text("With a YouTube video in front, press").font(Typeface.body)
                    Text("⌃⌥N").font(Typeface.mono)
                }
                .foregroundStyle(Palette.inkTertiary)
            } else {
                Text("Select several to pack them into one context.")
                    .font(Typeface.body)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
    }
}
