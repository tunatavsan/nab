import QuartzCore
import SwiftUI

// Windows (the panel, the toast) open and close with Core Animation springs, which run in the render
// server without waiting on the main thread. Content inside moves with SwiftUI springs, which keep
// their velocity when interrupted.

enum Motion {
    /// Hover lifts on tiles and icons: quick, with a little life.
    static let lift = Animation.spring(response: 0.32, dampingFraction: 0.62)
    /// Buttons, links, state flips.
    static let snap = Animation.spring(response: 0.3, dampingFraction: 0.7)
    /// Press feedback.
    static let press = Animation.spring(response: 0.2, dampingFraction: 0.7)
    /// Rows arriving, content swapping, the panel growing.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.84)

    /// `animation`, or a short fade when the user has asked for reduced motion.
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.15) : animation
    }
}

extension AnyTransition {
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

    static func spring(response: Double, damping: Double) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / response, 2)
        spring.damping = 4 * .pi * damping / response
        spring.duration = spring.settlingDuration
        spring.preferredFrameRateRange = frameRate
        return spring
    }

    /// Scale around the top centre plus the drop, for a layer whose origin is bottom-left.
    static func collapsed(size: CGSize) -> CATransform3D {
        let s = startScale
        let t = CATransform3DMakeTranslation((1 - s) * size.width / 2, (1 - s) * size.height + drop, 0)
        return CATransform3DScale(t, s, s, 1)
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
