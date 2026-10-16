import AppKit
import Carbon.HIToolbox
import NabAI
import NabCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let center = CaptureCenter()
    private lazy var assistant = Assistant(center: center)
    private var status: StatusController!
    private var rack: RackController!
    private var library: LibraryWindowController?
    private lazy var askWindow = AskWindowController(
        center: center, assistant: assistant,
        // ⌘O carries the conversation over, so even one video opens on its chat rather than its transcript.
        openLibrary: { [weak self] ids in self?.libraryWindow().show(select: ids, chat: true) },
        openVideo: { [weak self] id, seconds in self?.libraryWindow().showVideo(id, at: seconds) })

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if FrameProbe.enabled {
            FileHandle.standardError.write(
                Data("[frames] probe on, screen \(NSScreen.main?.maximumFramesPerSecond ?? 0) Hz\n".utf8))
        }
        NSApp.mainMenu = MainMenu.make()
        status = StatusController(
            center: center,
            actions: .init(
                nabFrontTab: { [weak self] in self?.nabFrontTab() },
                pasteLinks: { [weak self] in self?.center.pasteLinks() },
                exportTray: { [weak self] in self.map { Exporter.save($0.center.trayCaptures) } },
                openLibrary: { [weak self] id in self?.showLibrary(select: id) },
                summarize: { [weak self] ids in self?.summarize(ids) },
                openSettings: { [weak self] in self?.showSettings() },
                copyAll: { [weak self] in self?.center.copySession() },
                newSession: { [weak self] in self?.center.closeSession(announce: true) },
                openWelcome: { [weak self] in
                    self?.askWindow.close()
                    self?.libraryWindow().showWelcome()
                }))
        assistant.openSettings = { [weak self] in self?.showSettings() }
        PlaybackRouter.shared.title = { [weak self] id in self?.center.entry(id)?.title }
        rack = RackController(
            center: center, anchor: { [weak self] in self?.status.anchorRect },
            openLibrary: { [weak self] id in self?.showLibrary(select: id) },
            openSession: { [weak self] in self?.libraryWindow().showCurrentSession() },
            summarize: { [weak self] ids in self?.summarize(ids) })
        registerShortcuts()
        Task {
            await center.load()
            #if DEBUG
                FileHandle.standardError.write(Data("Nab keychain service: \(Keychain.service)\n".utf8))
                // Debug builds only: `NAB_OPEN='nab://…'` handles that URL as if it had been opened.
                if let raw = ProcessInfo.processInfo.environment["NAB_OPEN"], let url = URL(string: raw) {
                    application(NSApp, open: [url])
                }
            #endif
        }
    }

    private func registerShortcuts() {
        let shortcuts = ShortcutStore.shared
        shortcuts.onRegistered = { [weak self] in
            self?.center.shortcutAvailable = ShortcutStore.shared.isActive(.nab)
        }
        shortcuts.install(handlers: [
            .nab: { [weak self] in self?.nabFrontTab() },
            .copySession: { [weak self] in self?.center.copySession() },
            .summarize: { [weak self] in
                guard let self else { return }
                if askWindow.isVisible { askWindow.close() } else { summarize(center.sessionSummaryIDs()) }
            },
            .newSession: { [weak self] in self?.center.closeSession(announce: true) },
        ])
    }

    /// `nab://front` does what the shortcut does; `nab://add?url=…` adds links; `nab://chat?url=…` adds them and
    /// opens the floating AI window on them once they are fetched; `nab://copy` copies the open session's context;
    /// `nab://summarize` opens that window on the session; `nab://ask` opens it on the current scope with the field
    /// focused, and `nab://ask?q=<text>` pre-fills the field with that text. A link can come from any web page, so
    /// none of these sends anything: the user presses Summarize or Return (⌃⌥S and the Ask AI buttons summarize
    /// right away). `nab://close` starts a fresh session; `nab://menu` opens the menu bar panel; `nab://library`
    /// opens the window, `nab://library?id=<entry>` a video and `nab://library?session=current` the session's chat;
    /// `nab://settings` opens the settings page; `nab://search?q=<text>` opens the ⌘K palette with that text.
    /// Other tools (Shortcuts, Raycast, scripts, agents) can drive Nab through these.
    func application(_ application: NSApplication, open urls: [URL]) {
        // Timecode links that arrive from outside (another app or page).
        for citation in urls.compactMap(Citation.init(url:)) {
            if askWindow.isVisible { askWindow.open(citation) } else { libraryWindow().open(citation) }
        }
        for url in urls where url.scheme == "nab" {
            let links =
                URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .filter { $0.name == "url" }.compactMap(\.value).joined(separator: "\n") ?? ""
            switch url.host() {
            case "front": nabFrontTab()
            case "add": center.add(linksIn: links)
            case "chat":
                let ids = center.registry.links(in: links).compactMap { center.registry.match($0)?.entryID }
                center.add(linksIn: links)
                Task {
                    await center.waitForFetches(ids)
                    summarize(ids.filter { center.entry($0)?.capture != nil }, fromLink: true)
                }
            case "copy": center.copySession()
            case "summarize": summarize(center.sessionSummaryIDs(), fromLink: true)
            case "ask":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "q" }?.value
                askWindow.show(draft: AskScope.draft(fromLinkText: text), holdsSummary: true)
            case "close": center.closeSession(announce: true)
            case "menu": status.show()
            case "library":
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let id = query.first(where: { $0.name == "id" })?.value {
                    showLibrary(select: id)
                } else if query.contains(where: { $0.name == "session" && $0.value == "current" }) {
                    libraryWindow().showCurrentSession()
                } else {
                    showLibrary(select: nil)
                }
            case "settings": showSettings()
            case "search":
                let text = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "q" }?.value
                libraryWindow().showSearch(query: text ?? "")
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary(select: nil) }
        return true
    }

    private func nabFrontTab() {
        Task { await center.nabFrontTab() }
    }

    func showLibrary(select id: String?) {
        libraryWindow().show(select: id.map { [$0] } ?? [])
    }

    private func summarize(_ ids: [String], fromLink: Bool = false) {
        guard !ids.isEmpty else { return }
        askWindow.show(ids: ids, holdsSummary: fromLink)
    }

    private func libraryWindow() -> LibraryWindowController {
        if let library { return library }
        let created = LibraryWindowController(center: center, assistant: assistant)
        created.askInWindow = { [weak self] ids in self?.summarize(ids) }
        library = created
        return created
    }

    @objc func showSettings() {
        askWindow.close()
        libraryWindow().showSettings()
    }
}

enum MainMenu {
    /// Menus exist only while the library window is open, but text editing (⌘C, ⌘V, ⌘A) needs them.
    @MainActor static func make() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(
            withTitle: "About Nab", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""
        )
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Nab", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Nab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Nab")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: window, title: "Window")
        return main
    }
}

extension NSMenu {
    fileprivate func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
