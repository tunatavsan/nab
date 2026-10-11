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
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let center: CaptureCenter
    private var panel: FloatingPanel!
    private var monitors: [Any] = []
    private let light = CALayer()
    private var lastInFlight = 0

    init(center: CaptureCenter, actions: Actions) {
        self.center = center
        item.button?.image = Self.icon
        item.button?.setAccessibilityLabel("Nab")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        installLight()
        panel = FloatingPanel(size: NSSize(width: PanelMetrics.width, height: PanelMetrics.height(rows: 0))) {
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
                    }))
        }
        observe { [weak self] in
            guard let self else { return }
            self.panel.setHeight(PanelMetrics.height(rows: self.center.tray.count))
        }
        observe { [weak self] in
            guard let self else { return }
            self.updateLight(inFlight: self.center.inFlight)
        }
    }

    /// The icon's rect on screen; toasts hang from it.
    var anchorRect: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    @objc private func toggle() {
        panel.isVisible ? close() : open()
    }

    private func open() {
        panel.place(below: anchorRect)
        panel.present()
        panel.makeKey()
        monitors.append(
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            } as Any)
        monitors.append(
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == UInt16(kVK_Escape) {
                    self?.close()
                    return nil
                }
                return event
            } as Any)
    }

    private func close() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel.dismiss()
    }

    // MARK: Icon

    /// Two viewfinder corners around a dot.
    static let icon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let corners = NSBezierPath()
            corners.lineWidth = 1.6
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            corners.move(to: NSPoint(x: 3, y: 10.5))
            corners.line(to: NSPoint(x: 3, y: 15))
            corners.line(to: NSPoint(x: 7.5, y: 15))
            corners.move(to: NSPoint(x: 15, y: 7.5))
            corners.line(to: NSPoint(x: 15, y: 3))
            corners.line(to: NSPoint(x: 10.5, y: 3))
            Palette.nsTemplateInk.set()
            corners.stroke()
            NSBezierPath(ovalIn: NSRect(x: 6.6, y: 6.6, width: 4.8, height: 4.8)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()

    /// A 6 pt light in the icon's top-right corner: orange and pulsing while fetches run, a short
    /// green flash when the last one lands.
    private func installLight() {
        guard let button = item.button else { return }
        button.wantsLayer = true
        light.bounds = CGRect(x: 0, y: 0, width: 6, height: 6)
        light.cornerRadius = 3
        light.opacity = 0
        let b = button.bounds
        light.position = CGPoint(x: b.midX + 6.5, y: button.isFlipped ? b.minY + 5 : b.maxY - 5)
        button.layer?.addSublayer(light)
    }

    private func updateLight(inFlight: Int) {
        defer { lastInFlight = inFlight }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if inFlight > 0 {
            light.backgroundColor = Palette.nsAccent.cgColor
            let still = LightMotion.reduceMotion
            if light.opacity == 0 {
                light.opacity = 1
                if !still {
                    let pop = WindowMotion.layerSpring(
                        response: WindowMotion.popResponse, damping: WindowMotion.popDamping)
                    pop.keyPath = "transform.scale"
                    pop.fromValue = 0.2
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
            light.backgroundColor = Palette.nsOK.cgColor
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.beginTime = CACurrentMediaTime() + 0.6
            fade.duration = 0.15
            fade.fillMode = .backwards
            light.opacity = 0
            light.add(fade, forKey: "fade")
        }
        CATransaction.commit()
    }
}

private struct MenuPanelView: View {
    let center: CaptureCenter
    let actions: StatusController.Actions
    @State private var hoveredTool: String?

    var body: some View {
        let tray = center.tray
        VStack(spacing: PanelMetrics.gap) {
            tools
                .frame(height: PanelMetrics.toolsHeight)
                .cell()
            TrayCell(center: center, tray: tray, actions: actions)
                .frame(height: PanelMetrics.trayHeight(rows: tray.count))
                .cell()
            footer
                .frame(height: PanelMetrics.footerHeight)
                .cell()
        }
        .padding(PanelMetrics.ring)
        .frame(width: PanelMetrics.width)
        .ring()
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Motion.settle, value: tray.count)
    }

    private var tools: some View {
        HStack(spacing: 0) {
            ToolTile(
                symbol: "viewfinder", title: "Front Tab", shortcut: center.shortcutAvailable ? "⌃⌥N" : "no shortcut",
                hovered: $hoveredTool,
                action: actions.nabFrontTab)
            ToolTile(
                symbol: "clipboard", title: "Paste", shortcut: "links", hovered: $hoveredTool,
                action: actions.pasteLinks)
            ToolTile(
                symbol: "square.and.arrow.down", title: "Export", shortcut: ".md",
                enabled: !center.trayCaptures.isEmpty,
                hovered: $hoveredTool, action: actions.exportTray)
            ToolTile(symbol: "rectangle.stack", title: "Library", hovered: $hoveredTool) { actions.openLibrary(nil) }
        }
        .padding(.horizontal, Space.s)
    }

    private var footer: some View {
        HStack(spacing: Space.s) {
            Image(nsImage: StatusController.icon)
                .renderingMode(.template)
                .foregroundStyle(Palette.ink)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text("Nab").font(Typeface.button).foregroundStyle(Palette.ink)
                Text("\(center.entries.count) in library").font(Typeface.mono).foregroundStyle(Palette.inkTertiary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 6)
            IconButton(symbol: "gearshape", help: "Settings") { actions.openSettings() }
            IconButton(symbol: "power", help: "Quit Nab") { NSApp.terminate(nil) }
        }
        .padding(.horizontal, 10)
    }
}

private struct TrayCell: View {
    let center: CaptureCenter
    let tray: [Entry]
    let actions: StatusController.Actions

    var body: some View {
        let ready = tray.compactMap(\.capture)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s) {
                SectionLabel("Tray")
                if !tray.isEmpty {
                    Text(summary(ready))
                        .font(Typeface.mono)
                        .foregroundStyle(Palette.inkTertiary)
                        .contentTransition(.numericText())
                }
                Spacer()
                if !tray.isEmpty { LinkButton(title: "Clear", action: center.clearTray) }
            }
            .frame(height: PanelMetrics.headerHeight)
            .padding(.bottom, Space.s)

            Group {
                if tray.isEmpty {
                    empty
                } else {
                    ScrollView {
                        LazyVStack(spacing: PanelMetrics.rowSpacing) {
                            ForEach(tray) { entry in
                                TrayRow(entry: entry, center: center, actions: actions) {
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
            .padding(.bottom, PanelMetrics.listGap)

            HStack(spacing: Space.s) {
                PrimaryButton(
                    title: center.inFlight > 0 ? "Fetching…" : "Copy Context",
                    symbol: center.inFlight > 0 ? "hourglass" : "doc.on.doc",
                    trailing: ready.isEmpty ? nil : "\(ready.count)",
                    enabled: !ready.isEmpty,
                    action: center.copyTray)
                SecondaryIconButton(
                    symbol: "sparkles", help: "Summarize and chat about the tray", enabled: !ready.isEmpty
                ) {
                    actions.summarize(tray.filter { $0.capture != nil }.map(\.id))
                }
            }
        }
        .padding(PanelMetrics.cellPadding)
        .frameProbe("tray.insert", Double(tray.count))
        .animation(Motion.settle, value: tray.map(\.id))
    }

    private var empty: some View {
        VStack(spacing: Space.xs) {
            Text(
                center.shortcutAvailable
                    ? "Press ⌃⌥N with a YouTube video in front."
                    : "⌃⌥N is in use by another app. Use Front Tab above.")
            Text("Nabbed videos gather here, ready to copy as one context.")
        }
        .font(Typeface.meta)
        .foregroundStyle(Palette.inkTertiary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func summary(_ captures: [Capture]) -> String {
        let total = captures.compactMap(\.duration).reduce(0, +)
        return total > 0 ? "\(tray.count) · \(Timecode.string(total))" : "\(tray.count)"
    }
}

private struct TrayRow: View {
    let entry: Entry
    let center: CaptureCenter
    let actions: StatusController.Actions
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Thumb(entry: entry)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(Typeface.rowTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(entry.metaLine)
                        .font(Typeface.meta)
                        .foregroundStyle(entry.phase == .failed ? Palette.error : Palette.inkTertiary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: Space.xs)
                Text(entry.durationText)
                    .font(Typeface.mono)
                    .foregroundStyle(Palette.inkTertiary)
            }
            .padding(Space.xs)
            .frame(height: PanelMetrics.rowHeight)
            .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .contextMenu {
            if entry.phase == .failed { Button("Try Again") { center.retry(entry.id) } }
            Button("Open Video") { NSWorkspace.shared.open(entry.url) }
            Button("Copy Link") { Pasteboard.copy(entry.url.absoluteString) }
            if let capture = entry.capture {
                Button("Summarize") { actions.summarize([entry.id]) }
                Button("Copy Context") { Pasteboard.copy(ContextPack.render([capture])) }
            }
            Divider()
            Button("Remove from Tray") { center.removeFromTray(entry.id) }
        }
    }
}

/// A 40 pt round companion to the primary button: glass fill, hairline border, brightens on hover.
private struct SecondaryIconButton: View {
    let symbol: String
    let help: String
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.iconButton)
                .foregroundStyle(enabled ? (hovering ? Palette.accent : Palette.ink) : Palette.inkTertiary)
                .scaleEffect(hovering && enabled ? 1.1 : 1)
                .frame(width: PanelMetrics.buttonHeight, height: PanelMetrics.buttonHeight)
                .background(Circle().fill(hovering && enabled ? Palette.controlHover : Palette.control))
                .overlay(
                    Circle().strokeBorder(
                        hovering && enabled ? Palette.controlBorderHover : Palette.controlBorder, lineWidth: 1)
                )
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle(scale: 0.94))
        .disabled(!enabled)
        .help(help)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }
}
