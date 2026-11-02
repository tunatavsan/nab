import AppKit
import SwiftUI

/// Measures how often SwiftUI actually produces a new animation frame. Attach
/// `.frameProbe(label, value)` next to an animation driven by the same value: SwiftUI calls `animatableData`'s setter once per
/// rendered frame, so the gaps between calls are the real frame intervals. Enabled with
/// `NAB_FRAME_PROBE=1`; results go to stderr and `~/Library/Logs/Nab/frames.log`.
@MainActor
final class FrameProbe {
    static let shared = FrameProbe()
    nonisolated static let enabled = ProcessInfo.processInfo.environment["NAB_FRAME_PROBE"] == "1"

    private var stamps: [CFTimeInterval] = []
    private var label = ""
    private var finish: DispatchWorkItem?

    func tick(_ label: String) {
        guard Self.enabled else { return }
        if stamps.isEmpty { self.label = label }
        guard label == self.label else { return }
        // Several views can ask in one frame; calls closer than 2 ms are the same frame.
        let now = CACurrentMediaTime()
        if let last = stamps.last, now - last < 0.002 { return }
        stamps.append(now)
        finish?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.report() }
        finish = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Splits ticks into bursts (one animation each), maps each tick to the display frame it fell in,
    /// and reports how many of the burst's frames were actually drawn. 100 % at 120 Hz means every
    /// refresh carried a new frame.
    private func report() {
        defer { stamps = [] }
        let screenHz = NSScreen.main?.maximumFramesPerSecond ?? 60
        let period = 1 / Double(screenHz)
        var bursts: [[CFTimeInterval]] = [[]]
        for t in stamps {
            if let last = bursts[bursts.count - 1].last, t - last > 0.05 { bursts.append([]) }
            bursts[bursts.count - 1].append(t)
        }
        let animated = bursts.filter { $0.count >= 6 }
        guard !animated.isEmpty else { return }
        var line = ""
        for burst in animated {
            let start = burst[0]
            let drawn = Set(burst.map { Int((($0 - start) / period).rounded(.down)) }).count
            let span = Int(((burst.last! - start) / period).rounded(.down)) + 1
            let duration = (burst.last! - start) * 1000
            line += String(
                format: "[frames] %@ %.0fms drawn=%d/%d refreshes (%.0f%%) ≈%.0f fps screen=%dHz\n",
                label, duration, drawn, span, 100 * Double(drawn) / Double(span),
                Double(drawn) / max(duration / 1000, period), screenHz)
        }
        FileHandle.standardError.write(Data(line.utf8))
        // A run on its own data folder (NAB_DATA_DIR) logs there, never next to the installed app's log.
        let log =
            ProcessInfo.processInfo.environment["NAB_DATA_DIR"].map { URL(filePath: $0).appending(path: "frames.log") }
            ?? URL.libraryDirectory.appending(path: "Logs/Nab/frames.log")
        try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: log)
        }
    }
}

/// SwiftUI asks a `GeometryEffect` for its transform on every frame of an animation that moves its
/// `animatableData`, so each call marks one rendered frame.
struct FrameProbeEffect: GeometryEffect {
    var animatableData: Double
    let label: String

    nonisolated func effectValue(size: CGSize) -> ProjectionTransform {
        let label = label
        if Thread.isMainThread {
            MainActor.assumeIsolated { FrameProbe.shared.tick(label) }
        } else {
            DispatchQueue.main.async { FrameProbe.shared.tick(label) }
        }
        return ProjectionTransform()
    }
}

extension View {
    /// No cost unless `NAB_FRAME_PROBE=1`.
    @ViewBuilder func frameProbe(_ label: String, _ value: Double) -> some View {
        if FrameProbe.enabled { modifier(FrameProbeEffect(animatableData: value, label: label)) } else { self }
    }
}

extension AnyTransition {
    /// `transition`, plus a probe that ticks on every frame of its insertion. No cost unless `NAB_FRAME_PROBE=1`.
    static func probed(_ transition: AnyTransition, _ label: String) -> AnyTransition {
        guard FrameProbe.enabled else { return transition }
        return transition.combined(
            with: .modifier(
                active: FrameProbeEffect(animatableData: 0, label: label),
                identity: FrameProbeEffect(animatableData: 1, label: label)))
    }
}

extension View {
    /// Ticks the probe on every frame a scroll view's offset moves. No cost unless `NAB_FRAME_PROBE=1`.
    @ViewBuilder func scrollProbe(_ label: String) -> some View {
        if FrameProbe.enabled {
            onScrollGeometryChange(
                for: CGFloat.self, of: { $0.contentOffset.y }, action: { _, _ in FrameProbe.shared.tick(label) })
        } else {
            self
        }
    }
}
