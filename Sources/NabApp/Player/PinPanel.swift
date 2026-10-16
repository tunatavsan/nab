import AppKit
import Carbon.HIToolbox
import NabCore
import SwiftUI
import WebKit

struct PinActions {
    var close: () -> Void
    var unpin: () -> Void
    var openInBrowser: () -> Void
    var signIn: () -> Void
    var signOut: () -> Void
}

/// The pin: a floating, non-activating panel that holds the player. It stays in front until closed, moves by its
/// strip, resizes by its border with 16:9 kept, and remembers where and how big it is. Esc does not close it.
final class PinPanel: NSPanel {
    static let minVideoWidth: CGFloat = 320
    static let defaultVideoWidth: CGFloat = 384
    private static let frameKey = "player.pin.frame"

    let root: PinRootView
    var onToggle: () -> Void = {}
    private var animating = false

    init(state: PlayerState) {
        root = PinRootView(state: state)
        super.init(
            contentRect: NSRect(origin: .zero, size: root.panelSize(videoWidth: Self.defaultVideoWidth)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        contentView = root
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        animationBehavior = .none
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(remember), name: name, object: self)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    @objc private func remember() {
        guard !animating, isVisible else { return }
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.frameKey)
    }

    // MARK: Geometry

    /// The largest video width this screen allows: 60 % of it, either way.
    func maxVideoWidth() -> CGFloat {
        let visible = (screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return max(Self.minVideoWidth, min(visible.width * 0.6, visible.height * 0.6 * 16 / 9) - 2 * PinRootView.margin)
    }

    func clamped(videoWidth: CGFloat) -> CGFloat { min(max(videoWidth, Self.minVideoWidth), maxVideoWidth()) }

    /// Where the pin opens: where it was last left, else the lower right corner of the main screen.
    private func restoredFrame() -> NSRect {
        let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? .zero
        var frame = NSRect(origin: .zero, size: root.panelSize(videoWidth: Self.defaultVideoWidth))
        if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
            let rect = NSRectFromString(saved)
            if rect.width > 0, NSScreen.screens.contains(where: { $0.visibleFrame.intersects(rect) }) {
                let width = clamped(videoWidth: rect.width - 2 * PinRootView.margin)
                let size = root.panelSize(videoWidth: width)
                return NSRect(x: rect.minX, y: rect.maxY - size.height, width: size.width, height: size.height)
            }
        }
        frame.origin = NSPoint(x: visible.maxX - frame.width - Space.xl, y: visible.minY + Space.xl)
        return frame
    }

    // MARK: In and out

    /// Opens at its remembered place. With `from` (the embedded player's rect on screen) the panel starts there and
    /// flows to its place; with Reduce Motion on it simply appears.
    func open(from: NSRect?) {
        let target = restoredFrame()
        alphaValue = 1
        guard let from, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            setFrame(target, display: true)
            orderFrontRegardless()
            return
        }
        animating = true
        let margin = PinRootView.margin
        setFrame(from.insetBy(dx: -margin, dy: -margin), display: true)
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.4
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            self.animator().setFrame(target, display: true)
        } completionHandler: {
            MainActor.assumeIsolated {
                self.animating = false
                self.remember()
            }
        }
    }

    func dismiss() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard isVisible, !reduce, let layer = contentView?.layer else {
            orderOut(nil)
            return
        }
        let spring = WindowMotion.layerSpring(response: WindowMotion.closeResponse, damping: WindowMotion.closeDamping)
        spring.fromValue = CATransform3DIdentity
        spring.toValue = WindowMotion.collapsed(size: layer.bounds.size)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = 0.04
        fade.duration = 0.14
        fade.fillMode = .forwards
        spring.fillMode = .forwards
        let group = CAAnimationGroup()
        group.animations = [spring, fade]
        group.duration = 0.2
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                layer.removeAllAnimations()
            }
        }
        layer.add(group, forKey: "nab.close")
        CATransaction.commit()
    }

    /// Space plays and pauses, ⌘W closes; Esc is left alone, because a pin stays until it is closed.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
            let key = Int(event.keyCode)
            if flags.isEmpty, key == kVK_Space { return onToggle() }
            if flags == .command, key == kVK_ANSI_W { return root.actions.close() }
        }
        super.sendEvent(event)
    }
}

/// The panel's content: a thin black border around the 16:9 video. The border is the resize handle; the glass strip
/// over the video's top edge appears only while the pointer is in the panel.
final class PinRootView: NSView {
    static let margin: CGFloat = 6
    private static let stripHeight: CGFloat = 32

    var actions = PinActions(close: {}, unpin: {}, openInBrowser: {}, signIn: {}, signOut: {})
    private let strip: StripHost
    private var web: NSView?
    private var drag: (edges: Edges, frame: NSRect, mouse: NSPoint)?

    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    init(state: PlayerState) {
        strip = StripHost()
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Radius.card
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.cgColor
        strip.rootView = AnyView(
            PinStrip(
                state: state, close: { [weak self] in self?.actions.close() },
                unpin: { [weak self] in self?.actions.unpin() },
                openInBrowser: { [weak self] in self?.actions.openInBrowser() },
                signIn: { [weak self] in self?.actions.signIn() }, signOut: { [weak self] in self?.actions.signOut() }))
        strip.alphaValue = 0
        addSubview(strip)
        addTrackingArea(
            NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    func panelSize(videoWidth: CGFloat) -> NSSize {
        NSSize(width: videoWidth + 2 * Self.margin, height: (videoWidth * 9 / 16).rounded() + 2 * Self.margin)
    }

    func attach(_ web: NSView) {
        self.web = web
        web.removeFromSuperview()
        addSubview(web, positioned: .below, relativeTo: strip)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: Self.margin, dy: Self.margin)
        web?.frame = inner
        strip.frame = NSRect(
            x: inner.minX, y: inner.maxY - Self.stripHeight, width: inner.width, height: Self.stripHeight)
    }

    // MARK: Hover

    override func mouseEntered(with event: NSEvent) { setStrip(visible: true) }
    override func mouseExited(with event: NSEvent) { setStrip(visible: false) }

    private func setStrip(visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            strip.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: Resize by the border

    private func edges(at point: NSPoint) -> Edges {
        let slack = Self.margin + 10
        var edges: Edges = []
        if point.x < slack { edges.insert(.left) }
        if point.x > bounds.width - slack { edges.insert(.right) }
        if point.y < slack { edges.insert(.bottom) }
        if point.y > bounds.height - slack { edges.insert(.top) }
        return edges
    }

    override func resetCursorRects() {
        let m = Self.margin
        addCursorRect(NSRect(x: 0, y: 0, width: m, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: bounds.width - m, y: 0, width: m, height: bounds.height), cursor: .resizeLeftRight)
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: m), cursor: .resizeUpDown)
        addCursorRect(NSRect(x: 0, y: bounds.height - m, width: bounds.width, height: m), cursor: .resizeUpDown)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        drag = (edges(at: convert(event.locationInWindow, from: nil)), window.frame, NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window = window as? PinPanel else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - drag.mouse.x
        let dy = now.y - drag.mouse.y
        let start = drag.frame
        let m = Self.margin
        // The video's width follows whichever axis the border dragged; a corner follows the larger change.
        var fromX: CGFloat?
        var fromY: CGFloat?
        if drag.edges.contains(.left) { fromX = start.width - dx - 2 * m }
        if drag.edges.contains(.right) { fromX = start.width + dx - 2 * m }
        if drag.edges.contains(.top) { fromY = (start.height + dy - 2 * m) * 16 / 9 }
        if drag.edges.contains(.bottom) { fromY = (start.height - dy - 2 * m) * 16 / 9 }
        let candidates = [fromX, fromY].compactMap { $0 }
        guard let raw = candidates.max(by: { abs($0 - (start.width - 2 * m)) < abs($1 - (start.width - 2 * m)) }) else {
            return
        }
        let size = panelSize(videoWidth: window.clamped(videoWidth: raw))
        let x = drag.edges.contains(.left) ? start.maxX - size.width : start.minX
        let y = drag.edges.contains(.bottom) ? start.maxY - size.height : start.maxY - size.height
        window.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    override func mouseUp(with event: NSEvent) { drag = nil }
}

/// A hosting view that lets its empty glass drag the panel and is invisible to the pointer while hidden.
private final class StripHost: NSHostingView<AnyView> {
    init() { super.init(rootView: AnyView(EmptyView())) }
    required init(rootView: AnyView) { super.init(rootView: rootView) }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { alphaValue < 0.5 ? nil : super.hitTest(point) }
}

/// The glass strip: title, YouTube account menu, open on YouTube, unpin, close.
private struct PinStrip: View {
    let state: PlayerState
    let close: () -> Void
    let unpin: () -> Void
    let openInBrowser: () -> Void
    let signIn: () -> Void
    let signOut: () -> Void

    var body: some View {
        HStack(spacing: Space.xs) {
            Text(state.title)
                .font(Typeface.meta)
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button("Sign in to YouTube…", action: signIn)
                Button("Sign Out", action: signOut)
            } label: {
                Image(systemName: "ellipsis")
                    .font(Typeface.icon)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 30, height: 30)
                    .contentShape(.rect)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("YouTube account")
            IconButton(symbol: "arrow.up.right.square", help: "Open on YouTube", action: openInBrowser)
            IconButton(symbol: "pin.slash", help: "Unpin: back to the library window", action: unpin)
            IconButton(symbol: "xmark", help: "Close", action: close)
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }
}
