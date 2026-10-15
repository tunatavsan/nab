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
        window.titleVisibility = .hidden
        // The titlebar draws no material of its own, so the backdrop runs unbroken from top to bottom.
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.setContentSize(NSSize(width: 1240, height: 800))
        window.contentMinSize = NSSize(width: 960, height: 600)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NabLibrary")
        window.delegate = self
        if !window.setFrameUsingName("NabLibrary") { window.center() }
    }

    /// Brings the window forward. One id opens that video, several (or `chat`) open a session page.
    func show(select ids: [String], chat: Bool = false) {
        if chat || ids.count > 1 {
            if !ids.isEmpty { model.go(.session(ids)) }
        } else if let id = ids.first {
            model.go(.video(id))
        }
        bringForward()
    }

    func open(_ citation: Citation) { model.open(citation) }

    /// Opens a video's page with its transcript at `seconds`.
    func showVideo(_ id: String, at seconds: TimeInterval) {
        guard let entry = model.center.entry(id) else { return }
        model.open(entry, at: seconds)
        bringForward()
    }

    /// What "Ask in floating window" under an answer does; the app delegate sets it.
    var askInWindow: (([String]) -> Void)? {
        get { model.askInWindow }
        set { model.askInWindow = newValue }
    }

    func showSettings() {
        model.go(.settings)
        bringForward()
    }

    /// Opens the chat page of the capture session that is open now, or the home page when there is none.
    func showCurrentSession() {
        let ids = model.currentSessionIDs()
        model.go(ids.isEmpty ? .home : .session(ids))
        bringForward()
    }

    func showSearch(query: String) {
        model.searchQuery = query
        bringForward()
    }

    private func bringForward() {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
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

    enum Route: Hashable {
        case home
        case session([String])
        case video(String)
        case settings
    }

    private(set) var route = Route.home
    private(set) var backStack: [Route] = []
    private(set) var forwardStack: [Route] = []
    /// The ⌘K palette's text; nil while the palette is closed.
    var searchQuery: String?

    /// A transcript moment to scroll to; `token` makes a repeated click scroll again.
    struct Focus: Equatable {
        let entryID: String
        let seconds: TimeInterval
        let token = UUID()
    }
    var focus: Focus?
    /// Opens the floating AI window on these videos; set by the app delegate.
    @ObservationIgnored var askInWindow: (([String]) -> Void)?

    init(center: CaptureCenter, assistant: Assistant) {
        self.center = center
        self.assistant = assistant
    }

    func go(_ route: Route) {
        guard route != self.route else { return }
        backStack.append(self.route)
        forwardStack.removeAll()
        self.route = route
        // A page reads `focus` when it appears, so a moment from an earlier visit must not scroll the next one.
        focus = nil
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        route = previous
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        route = next
    }

    /// The videos the current page is about.
    var currentIDs: [String] {
        switch route {
        case .session(let ids): ids
        case .video(let id): [id]
        case .home, .settings: []
        }
    }

    func jump(to entryID: String, at seconds: TimeInterval) { focus = Focus(entryID: entryID, seconds: seconds) }

    /// Follows a timecode link from a chat. On a session or video page the transcript opens at that moment; with
    /// ⌘ held, or anywhere else, the video opens in the browser at that second.
    func open(_ citation: Citation) {
        let ids = assistant.conversation(currentIDs)?.entryIDs ?? currentIDs
        let videos = ids.compactMap { center.entry($0) }.filter { $0.capture != nil }
        let index = (citation.video ?? 1) - 1
        guard videos.indices.contains(index), let capture = videos[index].capture else { return }
        let inPage: Bool
        switch route {
        case .session, .video: inPage = !NSEvent.modifierFlags.contains(.command)
        case .home, .settings: inPage = false
        }
        if inPage {
            jump(to: videos[index].id, at: citation.seconds)
        } else {
            NSWorkspace.shared.open(capture.url(at: citation.seconds))
        }
    }

    /// The open session's ready videos, or else the latest ready one. Unlike `sessionSummaryIDs()` it does not
    /// mark the session as used, so the next nab still joins it.
    func currentSessionIDs() -> [String] {
        let ready = center.session.filter { $0.capture != nil }.map(\.id)
        if !ready.isEmpty { return ready }
        return center.entries.first { $0.capture != nil }.map { [$0.id] } ?? []
    }

    /// Opens a chat about `ids` and summarizes it unless that chat already started.
    func ask(about ids: [String]) {
        guard !ids.isEmpty else { return }
        searchQuery = nil
        go(.session(ids))
        Task { await assistant.summarizeIfNew(ids) }
    }

    /// Puts the context of the ready videos among `ids` on the clipboard.
    func copyContext(of ids: [String]) {
        let captures = ids.compactMap { center.entry($0)?.capture }
        guard !captures.isEmpty else { return }
        Pasteboard.copy(ContextPack.render(captures))
    }

    /// Opens a video's page with its transcript scrolled to `seconds`.
    func open(_ entry: Entry, at seconds: TimeInterval) {
        searchQuery = nil
        go(.video(entry.id))
        jump(to: entry.id, at: seconds)
    }

    /// Opens a chat about the current video (or the open session from the home page) and summarizes it
    /// unless that chat already started.
    func summarize() {
        let ids = currentIDs.isEmpty ? center.sessionSummaryIDs() : currentIDs
        guard !ids.isEmpty else { return }
        go(.session(ids))
        Task { await assistant.summarizeIfNew(ids) }
    }

    /// ⌘J: ask AI about the current page.
    func askAboutPage() {
        if case .session = route { return }
        let ids = currentIDs.isEmpty ? center.sessionSummaryIDs() : currentIDs
        guard !ids.isEmpty else { return }
        go(.session(ids))
    }

    var pageCaptures: [Capture] {
        let ids = currentIDs.isEmpty ? center.sessionSummaryIDs() : currentIDs
        return ids.compactMap { center.entry($0)?.capture }
    }

    func pack() -> String { ContextPack.render(pageCaptures) }

    func copyContext() {
        let captures = pageCaptures
        guard !captures.isEmpty else { return }
        Pasteboard.copy(ContextPack.render(captures))
    }

    /// The current chat as plain text, for pasting elsewhere.
    func copyChat() {
        guard let chat = assistant.conversation(currentIDs), !chat.messages.isEmpty else { return }
        Pasteboard.copy(
            chat.messages
                .map { ($0.role == .user ? "You" : "AI") + ": " + ($0.isSummaryRequest ? "Summarize" : $0.text) }
                .joined(separator: "\n\n"))
    }

    func export() { Exporter.save(pageCaptures) }

    func remove(_ entry: Entry) {
        center.remove([entry.id])
        if route == .video(entry.id) { go(.home) }
    }

    func open(_ entry: Entry) {
        searchQuery = nil
        go(.video(entry.id))
    }

    /// Title of the current page for the breadcrumb.
    var pageTitle: String {
        switch route {
        case .home: "Library"
        case .session(let ids):
            Set(ids) == Set(center.session.filter { $0.capture != nil }.map(\.id)) ? "This session" : "Chat"
        case .video(let id): center.entry(id)?.title ?? "Video"
        case .settings: "Settings"
        }
    }
}

/// Behind-window translucency for the library window: the desktop shows faintly, blurred and tinted.
private struct WindowBackdrop: View {
    var body: some View {
        ZStack {
            BehindWindowBlur()
            Palette.window.opacity(0.82)
        }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct LibraryView: View {
    @Bindable var model: LibraryModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollEdgeEffectStyle(.soft, for: .top)
                .blur(radius: model.searchQuery == nil ? 0 : 2)
            if model.searchQuery != nil {
                SearchPalette(model: model).transition(.opacity)
            }
        }
        .background { WindowBackdrop().ignoresSafeArea() }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // The breadcrumb names the page; without this the window title "Nab" sits next to it on inner pages.
        .toolbar(removing: .title)
        .animation(Motion.resolved(Motion.settle, reduceMotion: reduceMotion), value: model.route)
        .animation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion), value: model.searchQuery == nil)
        .toolbar { toolbar }
        .background { hiddenShortcuts }
    }

    @ViewBuilder private var page: some View {
        switch model.route {
        case .home:
            HomePage(model: model).transition(.opacity)
        case .session(let ids):
            SessionPage(ids: ids, model: model).id(Conversation.id(for: ids)).transition(.opacity)
        case .video(let id):
            VideoPage(entryID: id, model: model).id(id).transition(.opacity)
        case .settings:
            SettingsView(
                assistant: model.assistant, shortcutAvailable: model.center.shortcutAvailable,
                unavailableShortcuts: model.center.unavailableShortcuts
            )
            .transition(.opacity)
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left", action: model.goBack)
                .keyboardShortcut("[", modifiers: .command)
                .disabled(model.backStack.isEmpty)
                .help("Back (⌘[)")
            Button("Forward", systemImage: "chevron.right", action: model.goForward)
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.forwardStack.isEmpty)
                .help("Forward (⌘])")
            Breadcrumb(model: model)
        }
        ToolbarItem(placement: .principal) {
            SearchPill { model.searchQuery = "" }
                .keyboardShortcut("k", modifiers: .command)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch model.route {
            case .home:
                NabButton("Nab a link", shortcut: "⇧⌘V", action: model.center.pasteLinks)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .help("Add every YouTube link on the clipboard (⇧⌘V)")
            case .session:
                NabButton("Copy all", shortcut: "⇧⌘C", action: model.copyContext)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .help("Copy the videos as a context pack for AI (⇧⌘C)")
                NabButton("Copy chat", kind: .ghost, action: model.copyChat)
                    .help("Copy this conversation as text")
            case .video:
                NabButton("Open on YouTube", kind: .ghost) {
                    if case .video(let id) = model.route, let url = model.center.entry(id)?.url {
                        NSWorkspace.shared.open(url)
                    }
                }
            case .settings:
                EmptyView()
            }
            Button("Settings", systemImage: "gearshape") { model.go(.settings) }
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings (⌘,)")
        }
    }

    /// Shortcuts whose button is not on screen for the current page.
    @ViewBuilder private var hiddenShortcuts: some View {
        ZStack {
            Button("Ask AI", action: model.askAboutPage).keyboardShortcut("j", modifiers: .command)
            if model.route != .home, !isSession {
                Button("Copy context", action: model.copyContext).keyboardShortcut("c", modifiers: [.command, .shift])
            }
            if model.route != .home {
                Button("Paste links", action: model.center.pasteLinks)
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var isSession: Bool {
        if case .session = model.route { true } else { false }
    }
}

/// Library › This session › Learn Python
private struct Breadcrumb: View {
    let model: LibraryModel

    var body: some View {
        HStack(spacing: Space.xs) {
            if model.route == .home {
                Text("Library").font(Typeface.rowTitle).foregroundStyle(Palette.ink)
            } else {
                crumb("Library") { model.go(.home) }
                chevron
                if case .video(let id) = model.route, inSession(id) {
                    crumb("This session") { model.go(.session(model.currentSessionIDs())) }
                    chevron
                }
                Text(model.pageTitle)
                    .font(Typeface.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .frame(maxWidth: 200, alignment: .leading)
            }
        }
        .padding(.leading, Space.s)
        .accessibilityElement(children: .contain)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(Typeface.iconMicro).foregroundStyle(Palette.inkTertiary)
    }

    private func crumb(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(Typeface.meta)
            .foregroundStyle(Palette.inkTertiary)
            .help("Go to \(title)")
    }

    private func inSession(_ id: String) -> Bool { model.center.session.contains { $0.id == id && $0.capture != nil } }
}

/// The context menu of a video, wherever it is listed.
struct EntryContextMenu: ViewModifier {
    let entry: Entry
    let model: LibraryModel

    func body(content: Content) -> some View {
        content.contextMenu {
            Button(entry.phase == .failed ? "Try Again" : "Fetch Again") { model.center.retry(entry.id) }
            Button("Open in Browser") { NSWorkspace.shared.open(entry.url) }
            Button("Copy Link") { Pasteboard.copy(entry.url.absoluteString) }
            Divider()
            Button("Remove from Library", role: .destructive) { model.remove(entry) }
        }
    }
}

extension View {
    func entryContextMenu(_ entry: Entry, model: LibraryModel) -> some View {
        modifier(EntryContextMenu(entry: entry, model: model))
    }
}
