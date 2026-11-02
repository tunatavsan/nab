import Foundation

/// How long a held question waits for the records it asked about, measured with a monotonic clock that tests can
/// drive.
public enum HeldWait {
    /// Returns true when the wait ran out while a record was still being read.
    @MainActor
    public static func wait(
        limit: Duration = .seconds(AskScope.holdLimit), poll: Duration = .milliseconds(150),
        reading: () -> Bool, cancelled: () -> Bool, now: () -> ContinuousClock.Instant,
        sleep: (Duration) async -> Void
    ) async -> Bool {
        let start = now()
        while !cancelled(), reading() {
            if now() - start >= limit { return true }
            await sleep(poll)
        }
        return false
    }
}

/// The records the floating window is locked to once a question went in, and a counter that tells a late answer
/// whether the window moved on meanwhile.
public struct AskLockState: Equatable, Sendable {
    public private(set) var ids: [String]?
    public private(set) var generation = 0

    public init() {}

    /// A question was sent or held about `ids`: the window stays on that chat.
    public mutating func lock(_ ids: [String]) { self.ids = ids }

    /// The picker or a reopen: the lock goes and anything started before no longer counts.
    public mutating func reset() {
        ids = nil
        generation += 1
    }

    /// Locks only if nothing changed since `generation` was read.
    @discardableResult
    public mutating func lock(_ ids: [String], ifGeneration generation: Int) -> Bool {
        guard generation == self.generation else { return false }
        lock(ids)
        return true
    }
}
