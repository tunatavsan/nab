import AppKit
import QuartzCore
import SwiftUI

// Windows (the panel, the toast) open and close with Core Animation springs, which run in the render
// server without waiting on the main thread. Content inside moves with SwiftUI springs, which keep
// their velocity when interrupted.
//
// Every animation belongs to one class, and a class has one token and one transition. A new animation
// picks its class here instead of a curve of its own.
//
// | Class                          | Token                      | Transition              |
// | ------------------------------ | -------------------------- | ----------------------- |
// | Floating window in and out     | WindowMotion               | scale and drop, fade    |
// | Toast and rack                 | WindowMotion               | scale and drop, fade    |
// | Mini player in and out         | WindowMotion               | scale and drop, fade    |
// | Library window in and out      | system                     | system                  |
// | Menu and popover               | system (NSMenu, Menu)      | system                  |
// | Page change                    | Motion.pageIn              | .page                   |
// | Content change                 | Motion.settle              | .opacity, .rackCard     |
// | List insert and remove         | Motion.settle              | .rise                   |
// | Drawer in and out              | Motion.settle              | .drawer                 |
// | Floating window resize         | Motion.settle              | frame                   |
// | State flip (toggle, blur, tab) | Motion.snap                | none                    |
// | Hover highlight                | Motion.snap                | none                    |
// | Hover lift (tiles)             | Motion.lift                | none                    |
// | Press                          | Motion.press               | PressableStyle          |
//
// With Reduce Motion on, every SwiftUI class goes through `Motion.resolved` (a short fade) and the window
// classes stand still.

enum Motion {
    /// Hover lifts on tiles and icons: quick, with a slight overshoot.
    static let lift = Animation.spring(response: 0.32, dampingFraction: 0.62)
    /// Buttons, links, state flips.
    static let snap = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// Press feedback.
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
    /// Rows arriving, content swapping, the panel growing.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.84)
    /// A library page fading in; short, so a click feels instant and two pages never show at once.
    static let pageIn = Animation.easeOut(duration: 0.16)

    /// Fades a search hit's highlight back out.
    static let highlightFade = Animation.easeOut(duration: 0.8)

    /// `animation`, or a short fade when the user has asked for reduced motion.
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : animation
    }
}

extension AnyTransition {
    /// One view standing in for another (a library page, a chat's intro and its thread): the old one leaves at once
    /// and the new one fades in, so two layouts never blend into each other.
    static var page: AnyTransition {
        .asymmetric(insertion: .opacity.animation(Motion.pageIn), removal: .identity)
    }

    /// A side drawer sliding in from the trailing edge.
    static var drawer: AnyTransition { .move(edge: .trailing).combined(with: .opacity) }

    /// A card swapping for the next one in place, as the rack does.
    static var rackCard: AnyTransition { .opacity.combined(with: .scale(scale: 0.97, anchor: .top)) }

    static var rise: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(y: 6)).combined(with: .scale(scale: 0.96, anchor: .top)),
            removal: .opacity.combined(with: .scale(scale: 0.96)))
    }
}

/// Window entrance and exit, shared by the panel and the toast.
enum WindowMotion {
    static let openResponse = 0.36, openDamping = 0.78
    static let closeResponse = 0.3, closeDamping = 1.0
    /// The status item's activity light popping in.
    static let popResponse = 0.34, popDamping = 0.6
    static let startScale: CGFloat = 0.95
    /// The window starts this far above its resting place and drops into it.
    static let drop: CGFloat = 8
    static let frameRate = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)

    static func layerSpring(response: Double, damping: Double) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * damping / response
        spring.duration = spring.settlingDuration
        spring.preferredFrameRateRange = frameRate
        return spring
    }

    /// Scale around the top center plus the drop, for a layer whose origin is bottom-left.
    static func collapsed(size: CGSize) -> CATransform3D {
        let s = startScale
        let t = CATransform3DMakeTranslation((1 - s) * size.width / 2, (1 - s) * size.height + drop, 0)
        return CATransform3DScale(t, s, s, 1)
    }
}

/// Loops an opacity pulse for work in flight. With Reduce Motion on, the view stays still and fully lit.
private struct Pulse: ViewModifier {
    let low: Double
    let duration: Double
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.phaseAnimator([1.0, low]) { view, value in
                view.opacity(value)
            } animation: { _ in
                .easeInOut(duration: duration).delay(delay)
            }
        }
    }
}

extension View {
    func pulsing(low: Double, duration: Double, delay: Double = 0) -> some View {
        modifier(Pulse(low: low, duration: duration, delay: delay))
    }
}

/// The status item's light, which lives in Core Animation rather than SwiftUI.
@MainActor
enum LightMotion {
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func breathe() -> CABasicAnimation {
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 1
        breathe.toValue = 0.35
        breathe.duration = 0.7
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        return breathe
    }
}

/// Press feedback for custom controls: a small sink, sprung back.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(Motion.resolved(Motion.press, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}
