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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Top edge just under `anchor`, centered on it. If the icon is hidden (behind the notch or off a
    /// crowded menu bar), the panel goes to the top-right corner of the main screen.
    func place(below anchor: NSRect?, gap: CGFloat = 6) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? .zero
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
        host.layoutSubtreeIfNeeded()
        alphaValue = 1
        orderFrontRegardless()
        invalidateShadow()
        guard !wasVisible, !reduceMotion, let layer = host.layer else { return }
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
        guard isVisible else {
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
