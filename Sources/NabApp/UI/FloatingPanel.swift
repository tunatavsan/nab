import AppKit
import SwiftUI

/// A borderless, transparent panel for SwiftUI content that draws its own glass. It never activates
/// Nab, so the browser stays in front and keeps its tab selected. Opens and closes with a Core
/// Animation spring (see `WindowMotion`).
final class FloatingPanel: NSPanel {
    private let host: NSView
    private var motionToken = 0

    init<Content: View>(size: NSSize, level: NSWindow.Level = .popUpMenu, @ViewBuilder content: () -> Content) {
        let hosting = NSHostingView(rootView: content())
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        host = hosting
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: true)
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .none
        contentView = hosting
    }

    /// True during the dismiss animation, while the panel is still on screen but on its way out.
    var isClosing: Bool { host.layer?.animation(forKey: "nab.close") != nil }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Top edge just under `anchor`, centered on it. If the icon is hidden (behind the notch or off a
    /// crowded menu bar, or not placed yet), the panel goes to the top-right corner of the main screen.
    func place(below anchor: NSRect?, gap: CGFloat = 6) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        // Before the status item has been laid out its window sits at the screen origin; a real icon is in
        // the menu bar, above the visible frame.
        let anchor = anchor.flatMap { $0.minY >= visible.maxY - 1 ? $0 : nil }
        let notch: NSRect? = {
            guard let screen, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea else {
                return nil
            }
            return NSRect(x: left.maxX, y: left.minY, width: right.minX - left.maxX, height: left.height)
        }()
        let x: CGFloat
        if let anchor, anchor.minX >= visible.minX, anchor.maxX <= visible.maxX, !(notch?.intersects(anchor) ?? false) {
            x = anchor.midX - frame.width / 2
        } else {
            x = visible.maxX - frame.width
        }
        let top = min(anchor?.minY ?? visible.maxY, visible.maxY) - gap
        setFrameOrigin(NSPoint(x: min(max(x, visible.minX + 8), visible.maxX - frame.width - 8), y: top - frame.height))
    }

    /// Top centre of the screen under the mouse, `offset` below the top of its visible frame.
    func placeTopCenter(offset: CGFloat = 80) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
        setFrameOrigin(NSPoint(x: visible.midX - frame.width / 2, y: visible.maxY - offset - frame.height))
    }

    /// Changes height in one step, keeping the top edge where it is.
    func setHeight(_ height: CGFloat) {
        guard abs(frame.height - height) > 0.5 else { return }
        var next = frame
        next.origin.y = frame.maxY - height
        next.size.height = height
        setFrame(next, display: true, animate: false)
        invalidateShadow()
    }

    func present(reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) {
        motionToken += 1
        let wasVisible = isVisible
        // Reopened while lifting out: the close animation holds its last frame (collapsed, transparent) until
        // removed, so the panel would stay invisible. Drop it and open again.
        let closing = host.layer?.animation(forKey: "nab.close") != nil
        if closing { host.layer?.removeAllAnimations() }
        host.layoutSubtreeIfNeeded()
        alphaValue = 1
        orderFrontRegardless()
        invalidateShadow()
        guard !wasVisible || closing, !reduceMotion, let layer = host.layer else { return }
        layer.removeAllAnimations()

        let spring = WindowMotion.layerSpring(response: WindowMotion.openResponse, damping: WindowMotion.openDamping)
        spring.fromValue = WindowMotion.collapsed(size: host.bounds.size)
        spring.toValue = CATransform3DIdentity
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        fade.preferredFrameRateRange = WindowMotion.frameRate
        layer.add(spring, forKey: "nab.open.transform")
        layer.add(fade, forKey: "nab.open.opacity")
    }

    func dismiss(
        reduceMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, completion: (() -> Void)? = nil
    ) {
        guard isVisible, !isClosing else {
            completion?()
            return
        }
        motionToken += 1
        let token = motionToken
        guard !reduceMotion, let layer = host.layer else {
            orderOut(nil)
            completion?()
            return
        }
        let spring = WindowMotion.layerSpring(response: WindowMotion.closeResponse, damping: WindowMotion.closeDamping)
        spring.fromValue = CATransform3DIdentity
        spring.toValue = WindowMotion.collapsed(size: host.bounds.size)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = 0.04
        fade.duration = 0.14
        // The fade ends 20 ms before the group; without holding its end value the panel flashed back to full
        // opacity for those last two frames before `orderOut`.
        fade.fillMode = .forwards
        spring.fillMode = .forwards
        let group = CAAnimationGroup()
        group.animations = [spring, fade]
        group.duration = 0.2
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        group.preferredFrameRateRange = WindowMotion.frameRate
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.motionToken == token else { return }
                self.orderOut(nil)
                layer.removeAllAnimations()
                completion?()
            }
        }
        layer.add(group, forKey: "nab.close")
        CATransaction.commit()
    }
}

/// Re-runs `apply` whenever an observed property it reads changes.
@MainActor
func observe(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking(apply) {
        Task { @MainActor in observe(apply) }
    }
}
