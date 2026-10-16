import AppKit
import Carbon.HIToolbox
import NabCore
import SwiftUI

/// The menu bar icon and the panel it opens.
@MainActor
final class StatusController {
    struct Actions {
        let nabFrontTab: () -> Void
        let pasteLinks: () -> Void
        let exportTray: () -> Void
        let openLibrary: (String?) -> Void
        /// Opens the library's chat on these entries and summarizes them.
        let summarize: ([String]) -> Void
        let openSettings: () -> Void
        let copyAll: () -> Void
        let newSession: () -> Void
        /// The right-click menu's "Welcome…"; the panel itself never shows it.
        var openWelcome: () -> Void = {}
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let center: CaptureCenter
    private var panel: FloatingPanel!
    private var monitors: [Any] = []
    private let light = CAShapeLayer()
    private var lastInFlight = 0
    private var iconWidth = Glyph.width
    private let actions: Actions
    private var appliedStyle = StatusController.iconStyle

    init(center: CaptureCenter, actions: Actions) {
        self.center = center
        self.actions = actions
        item.button?.image = Self.makeIcon(count: 0, fetching: false)
        item.button?.setAccessibilityLabel("Nab")
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        NotificationCenter.default.addObserver(
            self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
        installLight()
        panel = FloatingPanel(
            size: NSSize(width: PanelMetrics.width, height: PanelMetrics.height(rows: 0, earlier: false)),
            cornerRadius: Radius.ring
        ) {
            MenuPanelView(
                center: center,
                actions: Actions(
                    nabFrontTab: { [weak self] in
                        self?.close()
                        actions.nabFrontTab()
                    },
                    pasteLinks: { actions.pasteLinks() },
                    exportTray: { [weak self] in
                        self?.close()
                        actions.exportTray()
                    },
                    openLibrary: { [weak self] id in
                        self?.close()
                        actions.openLibrary(id)
                    },
                    summarize: { [weak self] ids in
                        self?.close()
                        actions.summarize(ids)
                    },
                    openSettings: { [weak self] in
                        self?.close()
                        actions.openSettings()
                    },
                    copyAll: { [weak self] in
                        self?.close()
                        actions.copyAll()
                    },
                    newSession: { [weak self] in
                        self?.close()
                        actions.newSession()
                    }))
        }
        observe { [weak self] in
            guard let self else { return }
            self.panel.setHeight(
                PanelMetrics.height(
                    rows: self.center.tray.count,
                    earlier: RackText.earlierTodayCount(self.center.entries) > 0))
        }
        observe { [weak self] in
            guard let self else { return }
            self.updateLight(inFlight: self.center.inFlight)
        }
        observe { [weak self] in
            guard let self else { return }
            self.updateBadge(count: self.center.session.count, fetching: self.center.inFlight > 0)
        }
    }

    /// The icon's rect on screen; toasts hang from it.
    var anchorRect: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Left click toggles the panel; right click and ⌃-click open the menu.
    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            isShown ? close() : open()
        }
    }

    private func showMenu() {
        close()
        guard let button = item.button else { return }
        let style = Self.iconStyle
        let menu = NSMenu()
        for (title, value) in [("Icon Color", MenuBarIconStyle.color), ("Monochrome Icon", .mono)] {
            let entry = NSMenuItem(title: title, action: #selector(pickStyle(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = value.rawValue
            entry.state = style == value ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        for (title, selector) in [("Settings…", #selector(openSettingsItem)), ("Welcome…", #selector(openWelcomeItem))]
        {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Nab", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 5), in: button)
    }

    @objc private func pickStyle(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: Self.styleKey)
    }

    @objc private func openSettingsItem() { actions.openSettings() }
    @objc private func openWelcomeItem() { actions.openWelcome() }

    // MARK: Icon style

    static let styleKey = "menubar.iconStyle"
    private static var iconStyle: MenuBarIconStyle {
        MenuBarIconStyle(stored: UserDefaults.standard.string(forKey: styleKey))
    }

    /// Redraws the icon the moment the style changes, from the menu or from Settings.
    @objc private func defaultsChanged() {
        let style = Self.iconStyle
        guard style != appliedStyle else { return }
        appliedStyle = style
        updateBadge(count: center.session.count, fetching: center.inFlight > 0)
        light.fillColor = lightColor(fetching: center.inFlight > 0)
    }

    /// A panel on its way out counts as closed, so the next click or `nab://menu` opens it again.
    private var isShown: Bool { panel.isVisible && !panel.isClosing }

    /// Opens the panel if it is closed (`nab://menu`).
    func show() {
        if !isShown { open() }
    }

    private func open() {
        removeMonitors()
        if !panel.isVisible { panel.place(below: anchorRect) }
        panel.present()
        panel.makeKey()
        monitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Only the panel's own Esc; in the library or the floating window it belongs to them.
                if event.keyCode == UInt16(kVK_Escape), event.window === self?.panel {
                    self?.close()
                    return nil
                }
                return event
            } as Any)
    }

    private func close() {
        removeMonitors()
        panel.dismiss()
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    // MARK: Icon

    /// The app icon's mark on an 18 pt tall canvas: two quotes with their tails, the left one lime and the
    /// right one in the menu bar's ink. Coordinates are the board's 64-unit mark, drawn y down.
    private enum Glyph {
        static let width: CGFloat = 16
        static let height: CGFloat = 18
        /// 44 units of mark (head edge to head edge, both quotes) fit 15.84 pt.
        static let scale: CGFloat = 0.36
        /// Where the mark starts in the 64-unit space, and its vertical middle.
        static let originX: CGFloat = 11.5
        static let middleY: CGFloat = 32.5

        /// One quote (a round head flowing into a tapered tail) as a filled path; `side` 0 is the left one,
        /// 1 the right. `flipped` mirrors y for layers whose y axis points down.
        static func quote(side: Int, flipped: Bool = false) -> CGPath {
            let cx = 21.5 + CGFloat(side) * 24
            let cy: CGFloat = 25
            let path = CGMutablePath()
            path.move(to: CGPoint(x: cx - 10, y: cy))
            path.addArc(
                center: CGPoint(x: cx, y: cy), radius: 10, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
            path.addCurve(
                to: CGPoint(x: cx - 13, y: cy + 25), control1: CGPoint(x: cx + 10, y: cy + 11),
                control2: CGPoint(x: cx + 4, y: cy + 19.5))
            path.addCurve(
                to: CGPoint(x: cx - 10, y: cy), control1: CGPoint(x: cx - 7, y: cy + 16),
                control2: CGPoint(x: cx - 10, y: cy + 10))
            path.closeSubpath()
            let d = flipped ? scale : -scale
            var transform = CGAffineTransform(
                a: scale, b: 0, c: 0, d: d, tx: -originX * scale, ty: height / 2 - d * middleY)
            return path.copy(using: &transform) ?? path
        }
    }

    /// The lime for the menu bar, resolved when drawing: the dark-bar lime on dark, the darker lime-ink on
    /// light, so the mark stays readable on either.
    private static func markLime(dark: Bool) -> NSColor {
        dark ? Palette.nsAccent : NSColor(srgbRed: 0x4B / 255, green: 0x7A / 255, blue: 0x0E / 255, alpha: 1)
    }

    /// The icon, with the session's video count drawn to its right when there is one. Colored, it is not a
    /// template: the handler resolves colors for whichever menu bar it is drawn on. Mono is a template. While fetching, the left quote is left
    /// out because the breathing light layer draws it.
    private static func makeIcon(count: Int, fetching: Bool) -> NSImage {
        let mono = iconStyle == .mono
        let digits = NSAttributedString(
            string: "\(count)",
            attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
        let textWidth = count > 0 ? ceil(digits.size().width) : 0
        let width = Glyph.width + (count > 0 ? 4 + textWidth : 0)
        let image = NSImage(size: NSSize(width: width, height: Glyph.height), flipped: false) { _ in
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            if !fetching {
                context.addPath(Glyph.quote(side: 0))
                context.setFillColor((mono ? NSColor.black : markLime(dark: dark)).cgColor)
                context.fillPath()
            }
            context.addPath(Glyph.quote(side: 1))
            context.setFillColor((mono ? NSColor.black : NSColor.labelColor).cgColor)
            context.fillPath()
            if count > 0 {
                let ink = NSMutableAttributedString(attributedString: digits)
                ink.addAttribute(
                    .foregroundColor, value: mono ? NSColor.black : NSColor.labelColor,
                    range: NSRange(location: 0, length: ink.length))
                ink.draw(at: NSPoint(x: Glyph.width + 4, y: (Glyph.height - ink.size().height) / 2))
            }
            return true
        }
        // Mono is a template: the menu bar tints it white on a dark bar and black on a light one.
        image.isTemplate = mono
        return image
    }

    private func updateBadge(count: Int, fetching: Bool) {
        guard let button = item.button else { return }
        let image = Self.makeIcon(count: count, fetching: fetching)
        iconWidth = image.size.width
        item.length = count > 0 ? NSStatusItem.variableLength : NSStatusItem.squareLength
        button.image = image
        button.setAccessibilityLabel(count > 0 ? "Nab, \(count) in session" : "Nab")
        // The button resizes on the next layout pass; the light follows the image, which stays centred.
        DispatchQueue.main.async { [weak self] in self?.placeLight() }
    }

    /// The light is the left quote itself: it breathes while fetches run, and flashes in the menu bar's ink
    /// when the last one lands.
    private func installLight() {
        guard let button = item.button else { return }
        button.wantsLayer = true
        light.opacity = 0
        placeLight()
        button.layer?.addSublayer(light)
    }

    /// The image sits centred in the button; the layer shares the button's axes, which may point down.
    private func placeLight() {
        guard let button = item.button else { return }
        let b = button.bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        light.frame = CGRect(
            x: b.midX - iconWidth / 2, y: b.midY - Glyph.height / 2, width: Glyph.width, height: Glyph.height)
        light.path = Glyph.quote(side: 0, flipped: button.isFlipped)
        light.fillColor = lightColor(fetching: true)
        CATransaction.commit()
    }

    private func lightColor(fetching: Bool) -> CGColor {
        var color = Palette.nsAccent.cgColor
        let mono = Self.iconStyle == .mono
        let appearance = item.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            let dark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            color = (fetching && !mono ? Self.markLime(dark: dark) : NSColor.labelColor).cgColor
        }
        return color
    }

    private func updateLight(inFlight: Int) {
        defer { lastInFlight = inFlight }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if inFlight > 0 {
            light.fillColor = lightColor(fetching: true)
            let still = LightMotion.reduceMotion
            if light.opacity == 0 {
                light.opacity = 1
                if !still {
                    let pop = WindowMotion.layerSpring(
                        response: WindowMotion.popResponse, damping: WindowMotion.popDamping)
                    pop.keyPath = "transform.scale"
                    pop.fromValue = 0.6
                    pop.toValue = 1
                    light.add(pop, forKey: "pop")
                }
            }
            if still {
                light.removeAnimation(forKey: "breathe")
            } else if light.animation(forKey: "breathe") == nil {
                light.add(LightMotion.breathe(), forKey: "breathe")
            }
        } else if lastInFlight > 0 {
            light.removeAnimation(forKey: "breathe")
            light.fillColor = lightColor(fetching: false)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = CACurrentMediaTime() + 0.4
            fade.duration = 0.15
            fade.fillMode = .backwards
            light.opacity = 0
            light.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }
}

// MARK: Panel

private struct MenuPanelView: View {
    let center: CaptureCenter
    let actions: StatusController.Actions

    var body: some View {
        let tray = center.tray
        let earlier = RackText.earlierTodayCount(center.entries)
        VStack(spacing: PanelMetrics.gap) {
            SessionCell(center: center, tray: tray, actions: actions)
                .frame(height: PanelMetrics.sessionHeight(rows: tray.count))
                .background(Palette.raised, in: .rect(cornerRadius: Radius.cell, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.cell, style: .continuous).strokeBorder(Palette.line))
            actionButtons(tray)
                .frame(height: PanelMetrics.actionsHeight)
            menu(earlier: earlier)
                .frame(height: PanelMetrics.menuHeight(earlier: earlier > 0))
        }
        .padding(PanelMetrics.ring)
        .frame(width: PanelMetrics.width)
        .ring()
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Motion.settle, value: tray.count)
    }

    private func actionButtons(_ tray: [Entry]) -> some View {
        let ready = tray.contains { $0.capture != nil }
        let shortcuts = ShortcutStore.shared
        func key(_ action: ShortcutAction) -> KeyCombo? {
            shortcuts.isActive(action) ? shortcuts.combo(for: action) : nil
        }
        return HStack(spacing: PanelMetrics.gap) {
            ActionTile(label: "Copy all", combo: key(.copySession), enabled: ready, action: actions.copyAll)
            ActionTile(
                label: "Ask AI", combo: key(.summarize), primary: true, enabled: ready
            ) {
                actions.summarize(center.sessionSummaryIDs())
            }
            ActionTile(
                label: "New session", combo: key(.newSession), enabled: !tray.isEmpty, action: actions.newSession)
        }
    }

    private func menu(earlier: Int) -> some View {
        VStack(spacing: 0) {
            MenuRow(
                label: "Nab the YouTube tab in front",
                trailing: ShortcutStore.shared.isActive(.nab) ? nil : "no shortcut",
                combo: ShortcutStore.shared.isActive(.nab) ? ShortcutStore.shared.combo(for: .nab) : nil,
                action: actions.nabFrontTab)
            MenuRow(label: "Paste links", action: actions.pasteLinks)
            MenuRow(label: "Export session…", enabled: !center.trayCaptures.isEmpty, action: actions.exportTray)
            if earlier > 0 {
                MenuRow(label: RackText.earlierToday(count: earlier), trailing: "›") { actions.openLibrary(nil) }
            }
            Rectangle().fill(Palette.line).frame(height: 1).padding(.horizontal, Space.s).padding(.vertical, 4)
            MenuRow(label: "Open Library") { actions.openLibrary(nil) }
            MenuRow(label: "Settings…", trailing: "⌘,", action: actions.openSettings)
        }
        .padding(.vertical, PanelMetrics.menuPadding)
    }
}

private struct SessionCell: View {
    let center: CaptureCenter
    let tray: [Entry]
    let actions: StatusController.Actions

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.headerGap) {
            header
                .frame(height: PanelMetrics.headerHeight)
            Group {
                if tray.isEmpty {
                    empty
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(tray) { entry in
                                TrayRow(
                                    entry: entry, onClipboard: entry.id == clipboardID, center: center, actions: actions
                                ) {
                                    actions.openLibrary(entry.id)
                                }
                                .transition(.rise)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .scrollDisabled(tray.count <= PanelMetrics.visibleRows)
                }
            }
            .frame(height: PanelMetrics.listHeight(rows: tray.count))
        }
        .padding(PanelMetrics.cellPadding)
        .frameProbe("tray.insert", Double(tray.count))
        .animation(Motion.settle, value: tray.map(\.id))
    }

    /// The entry whose context the auto-copy last put on the clipboard: the newest of those it copied.
    private var clipboardID: String? { tray.first { center.copiedIDs.contains($0.id) }?.id }

    private var header: some View {
        HStack(spacing: Space.s) {
            LiveDot()
            Text("This session").font(Typeface.rowTitle).foregroundStyle(Palette.ink)
            if !tray.isEmpty {
                Text(RackText.videos(tray.count))
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: Space.s)
            if let start = tray.map(\.addedAt).min() {
                Text("since \(start.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute()))")
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }

    private var empty: some View {
        let shortcuts = ShortcutStore.shared
        let name = shortcuts.text(for: .nab) ?? "the shortcut"
        return Text(
            shortcuts.isActive(.nab)
                ? "Press \(name) with a YouTube video in front, and it lands here."
                : shortcuts.combo(for: .nab) == nil
                    ? "Nab the tab from the list below, or set a shortcut in Settings."
                    : "Nab the tab from the list below; \(name) is in use by another app."
        )
        .font(Typeface.meta)
        .foregroundStyle(Palette.inkTertiary)
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
    }
}

private struct TrayRow: View {
    let entry: Entry
    let onClipboard: Bool
    let center: CaptureCenter
    let actions: StatusController.Actions
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Thumbnail(entry: entry, width: 56, radius: Radius.chip)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(Typeface.button)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    status.contentTransition(.opacity)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
            .frame(height: PanelMetrics.rowHeight)
            .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .animation(Motion.snap, value: entry.phase)
        .accessibilityLabel("\(entry.title), \(statusText)")
        .accessibilityHint("Opens it in the library")
        .contextMenu {
            if entry.phase == .failed { Button("Try Again") { center.retry(entry.id) } }
            Button("Open Video") { PlaybackRouter.shared.openInBrowser(entryID: entry.id) }
            Button("Copy Link") { Pasteboard.copy(entry.url.absoluteString) }
            if let capture = entry.capture {
                Button("Summarize") { actions.summarize([entry.id]) }
                Button("Copy Context") { Pasteboard.copy(ContextPack.render([capture])) }
            }
            Divider()
            Button("Remove from Session") { center.removeFromTray(entry.id) }
        }
    }

    private var statusText: String {
        switch entry.phase {
        case .fetching: "Fetching captions…"
        case .failed: entry.failure ?? "Failed"
        case .ready: onClipboard ? "On clipboard" : entry.detailLine
        }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 5) {
            switch entry.phase {
            case .fetching:
                LimeSpinner(size: 9)
                Text(statusText).foregroundStyle(Palette.inkSecondary)
            case .failed:
                Text(statusText).foregroundStyle(Palette.error)
            case .ready:
                if onClipboard {
                    Image(systemName: "checkmark").font(Typeface.iconMicro).foregroundStyle(Palette.accentInk)
                    Text(statusText).foregroundStyle(Palette.ink)
                } else {
                    Text(statusText).foregroundStyle(Palette.inkTertiary)
                }
            }
        }
        .font(Typeface.meta)
        .lineLimit(1)
    }
}

/// A small spinner: a soft track with a lime arc turning on it. Still when Reduce Motion is on.
struct LimeSpinner: View {
    var size: CGFloat = 9
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            let angle =
                reduceMotion
                ? 0 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            ZStack {
                Circle().stroke(Palette.accentSoft, lineWidth: 1.5)
                Circle().trim(from: 0, to: 0.25).stroke(
                    Palette.accentInk, style: .init(lineWidth: 1.5, lineCap: .round)
                )
                .rotationEffect(.degrees(angle - 90))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// One of the three equal buttons under the session: a label over its shortcut.
private struct ActionTile: View {
    let label: String
    var combo: KeyCombo?
    var primary = false
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Text(label).font(Typeface.button)
                KeyCaps(combo, surface: primary ? .accent : .neutral)
            }
            .foregroundStyle(primary ? Palette.onAccent : Palette.ink)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(fill, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.line)
                }
            }
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .accessibilityLabel(label)
    }

    private var fill: Color {
        if primary { return hovering ? Palette.accent.opacity(0.9) : Palette.accent }
        return hovering ? Palette.selected : Palette.raised
    }
}

/// A line of the list under the buttons: label, optional shortcut or chevron, hover fill.
private struct MenuRow: View {
    let label: String
    var trailing: String?
    var combo: KeyCombo?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(label).font(Typeface.body).foregroundStyle(Palette.ink)
                Spacer(minLength: Space.s)
                if let trailing {
                    Text(trailing).font(Typeface.mono).foregroundStyle(Palette.inkTertiary)
                }
                KeyCaps(combo)
            }
            .padding(.horizontal, 10)
            .frame(height: PanelMetrics.menuRowHeight)
            .background(hovering && enabled ? Palette.hover : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }
}

extension Entry {
    /// "Turkish · ~13k tokens": the line under a finished video in the panel and the rack.
    var detailLine: String {
        guard let capture else { return "" }
        let characters = capture.transcript?.segments.reduce(0) { $0 + $1.text.utf8.count + 1 }
        return RackText.detail(
            language: capture.transcript?.languageName,
            tokens: characters.map { RackText.estimatedTokens(characters: $0) })
    }
}
