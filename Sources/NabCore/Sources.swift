import Foundation

/// Reads one family of links. A provider must be cheap to ask `identify` (no network) and do all
/// network work in `fetch`.
public protocol SourceProvider: Sendable {
    var kind: SourceKind { get }
    /// Returns the source's stable id for `url`, or nil when this provider does not handle it.
    func identify(_ url: URL) -> String?
    func fetch(_ url: URL) async throws -> Capture
}

public struct SourceRegistry: Sendable {
    public let providers: [any SourceProvider]
    public init(_ providers: [any SourceProvider]) { self.providers = providers }

    public func match(_ url: URL) -> (provider: any SourceProvider, entryID: String)? {
        for provider in providers {
            if let id = provider.identify(url) { return (provider, "\(provider.kind.rawValue):\(id)") }
        }
        return nil
    }

    /// Finds every supported link in free text (a pasted list, a note, a chat message), in order, deduplicated.
    public func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url, let hit = self.match(url), seen.insert(hit.entryID).inserted else { return nil }
            return url
        }
    }
}

public struct NabError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Bounds how many fetches run at once so twenty captures do not open twenty sockets to one host.
public actor Gate {
    private let limit: Int
    private var running = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) { self.limit = limit }

    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
        if running >= limit {
            await withCheckedContinuation { waiting.append($0) }
        } else {
            running += 1
        }
        defer {
            if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().resume() }
        }
        return try await work()
    }
}
