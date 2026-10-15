import Foundation

/// Captures nabbed together: one session is a burst of videos pasted into one AI conversation.
public struct SessionGroup: Identifiable, Sendable, Hashable {
    public let id: String
    public let start: Date
    public let end: Date
    /// Newest first.
    public let entryIDs: [String]
}

public enum SessionGrouping {
    /// Groups by `sessionID`; entries saved before sessions existed cluster by time instead, a pause longer
    /// than `gap` seconds starting a new group. Newest group first.
    public static func groups(_ entries: [Entry], gap: TimeInterval = 300) -> [SessionGroup] {
        var explicit: [String: [Entry]] = [:]
        var legacy: [Entry] = []
        for entry in entries {
            if let id = entry.sessionID { explicit[id, default: []].append(entry) } else { legacy.append(entry) }
        }
        var result = explicit.map { make($0.key, $0.value) }
        var cluster: [Entry] = []
        func flush() {
            guard let first = cluster.first else { return }
            result.append(make("legacy-\(Int(first.addedAt.timeIntervalSince1970))", cluster))
            cluster = []
        }
        for entry in legacy.sorted(by: { $0.addedAt < $1.addedAt }) {
            if let last = cluster.last, entry.addedAt.timeIntervalSince(last.addedAt) > gap { flush() }
            cluster.append(entry)
        }
        flush()
        return result.sorted { ($0.end, $0.id) > ($1.end, $1.id) }
    }

    private static func make(_ id: String, _ entries: [Entry]) -> SessionGroup {
        let sorted = entries.sorted { ($0.addedAt, $0.id) > ($1.addedAt, $1.id) }
        return SessionGroup(
            id: id, start: sorted.last?.addedAt ?? .distantPast, end: sorted.first?.addedAt ?? .distantPast,
            entryIDs: sorted.map(\.id))
    }

    /// Whether a nab at `now` must open a fresh session instead of joining the open one.
    public static func shouldStartNewSession(
        now: Date, lastActivity: Date?, consumed: Bool, hasSession: Bool, idle: TimeInterval
    ) -> Bool {
        guard hasSession, !consumed, let lastActivity else { return true }
        return now.timeIntervalSince(lastActivity) > idle
    }
}
