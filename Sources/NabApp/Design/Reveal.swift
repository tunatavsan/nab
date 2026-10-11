import SwiftUI

/// How answers write themselves in: each glyph sharpens out of a blur and settles a few points,
/// in reading order, behind a soft edge.
enum RevealMotion {
    /// Glyphs in the soft edge: how many are mid-reveal at once.
    static let window: Double = 26
    static let blur: Double = 5
    static let rise: Double = 3
    /// The edge closes the gap to the arrived text with this time constant (seconds)…
    static let tau: Double = 0.3
    /// …and never moves slower than this (glyphs per second).
    static let minSpeed: Double = 80
}

/// Draws a text's glyphs up to a moving edge. Layout never changes, only drawing, so the reveal
/// costs no re-layout and runs at the display's full rate.
struct RevealRenderer: TextRenderer {
    /// The edge, in glyphs from this text's first glyph; a glyph is fully drawn once the edge is
    /// `window` glyphs past it.
    var head: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let total = Double(layout.reduce(0) { sum, line in line.reduce(sum) { $0 + $1.count } })
        guard head < total + RevealMotion.window else {
            for line in layout { context.draw(line) }
            return
        }
        var index = 0.0
        for line in layout {
            for run in line {
                for glyph in run {
                    let t = min(max((head - index) / RevealMotion.window, 0), 1)
                    index += 1
                    // Later glyphs only sit further behind the edge.
                    guard t > 0 else { return }
                    guard t < 1 else {
                        context.draw(glyph)
                        continue
                    }
                    var copy = context
                    copy.opacity = t
                    copy.addFilter(.blur(radius: (1 - t) * RevealMotion.blur))
                    copy.translateBy(x: 0, y: (1 - t) * RevealMotion.rise)
                    copy.draw(glyph)
                }
            }
        }
    }
}

/// Moves the reveal edge toward the text that has arrived: quickly when a large chunk lands, never
/// slower than `minSpeed`, so a stream that arrives in bursts reads as one continuous motion.
/// One clock per streamed answer; the edge lives here, not in a view, so a rebuilt view resumes it.
@MainActor
@Observable
final class RevealClock {
    /// The stream ended and every glyph is drawn; views drop the timeline and draw plain text.
    private(set) var finished = false
    /// Set false when the stream ends; the edge then runs past the last glyph.
    @ObservationIgnored var streaming = true
    @ObservationIgnored private var head = 0.0
    @ObservationIgnored private var last: Date?
    @ObservationIgnored private var finishing = false

    /// Advances to `date` and returns the edge for a text of `length` glyphs.
    func head(at date: Date, length: Int) -> Double {
        FrameProbe.shared.tick("chat.reveal")
        let dt = last.map { max(0, min(date.timeIntervalSince($0), 1.0 / 20)) } ?? 0
        last = date
        // While streaming, the edge rests partway into the soft edge, so the newest words wait half-formed.
        let target = Double(length) + RevealMotion.window * (streaming ? 0.6 : 1)
        let gap = target - head
        if gap > 0 {
            head = min(target, head + max(gap * (1 - exp(-dt / RevealMotion.tau)), RevealMotion.minSpeed * dt))
        }
        if !streaming, head >= target, !finishing {
            finishing = true
            Task { @MainActor in self.finished = true }
        }
        return head
    }

    /// Clocks of messages still revealing; pruned as they finish. A message whose stream fails is never asked
    /// for its clock again, so the registry is also capped, dropping the oldest.
    private static var clocks: [UUID: RevealClock] = [:]
    private static let capacity = 16
    @ObservationIgnored private let created = Date()

    /// The clock of a message being written, created when it starts streaming.
    static func clock(for id: UUID, streaming: Bool) -> RevealClock? {
        if let clock = clocks[id] {
            clock.streaming = streaming
            // A finished clock is returned once more so the caller sees `finished`, then forgotten.
            if clock.finished, !streaming { clocks[id] = nil }
            return clock
        }
        guard streaming else { return nil }
        clocks = clocks.filter { !$0.value.finished }
        if clocks.count >= capacity, let oldest = clocks.min(by: { $0.value.created < $1.value.created }) {
            clocks[oldest.key] = nil
        }
        let clock = RevealClock()
        clocks[id] = clock
        return clock
    }
}
