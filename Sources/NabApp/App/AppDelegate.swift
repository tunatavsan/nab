import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let center = CaptureCenter()
    private lazy var assistant = Assistant(center: center)
    private var status: StatusController!
    private var toast: ToastController!
    private var library: LibraryWindowController?
    private var hotKey: HotKey?

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
                openSettings: { [weak self] in self?.showSettings() }))
        assistant.openSettings = { [weak self] in self?.showSettings() }
        toast = ToastController(center: center) { [weak self] in self?.status.anchorRect }
        do {
            hotKey = try HotKey(keyCode: kVK_ANSI_N, modifiers: controlKey | optionKey, id: 1) { [weak self] in
                self?.nabFrontTab()
            }
        } catch {
            NSLog("Nab: the ⌃⌥N shortcut is unavailable: %@", error.localizedDescription)
        }
        Task { await center.load() }
    }

    /// `nab://front` does what the shortcut does; `nab://add?url=…` adds links; `nab://chat?url=…` adds
    /// them and opens a chat that starts with a summary; `nab://library` opens the window. Other tools
    /// (Shortcuts, Raycast, scripts, agents) can drive Nab through these.
    func application(_ application: NSApplication, open urls: [URL]) {
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
                    // Wait for the transcripts (they usually take under a second).
                    for _ in 0..<150 where ids.contains(where: { center.entry($0)?.phase == .fetching }) {
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                    summarize(ids.filter { center.entry($0)?.capture != nil })
                }
            case "library": showLibrary(select: nil)
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

    private func summarize(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        libraryWindow().show(select: ids, chat: true)
        Task { await assistant.summarizeIfNew(ids) }
    }

    private func libraryWindow() -> LibraryWindowController {
        if let library { return library }
        let created = LibraryWindowController(center: center, assistant: assistant)
        library = created
        return created
    }

    @objc func showSettings() {
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
