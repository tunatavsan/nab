import Foundation

/// Reads one family of links. A provider must be cheap to ask `identify` and `isShortLink` (no network) and do all
/// network work in `expand`, `fetch` and `save`. Every capability past `kind`, `identify` and `fetch` has a default,
/// so a new source only writes what differs.
public protocol SourceProvider: Sendable {
    var kind: SourceKind { get }
    /// The source's name as people know it ("YouTube").
    var name: String { get }
    /// Returns the source's stable id for `url`, or nil when this provider does not handle it.
    func identify(_ url: URL) -> String?
    /// A link that names an item only after one request (a share link like `pin.it/…`). No network.
    func isShortLink(_ url: URL) -> Bool
    /// Follows a short link to the item's own link, with one request.
    func expand(_ url: URL) async throws -> URL
    func fetch(_ url: URL) async throws -> Capture
    /// Cover images for an item, largest first, known from its id alone so they show before the fetch ends.
    func covers(forID id: String) -> [URL]
    /// A link that opens the item at a moment.
    func link(to capture: Capture, at seconds: TimeInterval) -> URL
    /// Writes one photo or clip of `capture` to `file`; `capture` lets a source resolve an address that has expired.
    /// The default streams `media.url` to disk through the shared downloader. `progress` gets the bytes received and,
    /// when the server says, the bytes expected.
    func save(
        _ media: Media, of capture: Capture, to file: URL,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws
}

extension SourceProvider {
    public var name: String { kind.rawValue.capitalized }
    public func isShortLink(_ url: URL) -> Bool { false }
    public func expand(_ url: URL) async throws -> URL { url }
    public func covers(forID id: String) -> [URL] { [] }
    public func link(to capture: Capture, at seconds: TimeInterval) -> URL { capture.url }
    public func save(
        _ media: Media, of capture: Capture, to file: URL,
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws {
        try await MediaDownloader.shared.download(media.url, to: file, progress: progress)
    }
}

public struct SourceRegistry: Sendable {
    public let providers: [any SourceProvider]
    public init(_ providers: [any SourceProvider]) { self.providers = providers }

    public func provider(for kind: SourceKind) -> (any SourceProvider)? { providers.first { $0.kind == kind } }

    /// An entry's cover images, largest first: the source's own, then the one its fetch found.
    public func covers(for entry: Entry) -> [URL] {
        let own = provider(for: entry.source)?.covers(forID: entry.sourceID) ?? []
        return own + [entry.capture?.thumbnailURL].compactMap { $0 }.filter { !own.contains($0) }
    }

    public func link(to capture: Capture, at seconds: TimeInterval) -> URL {
        provider(for: capture.source)?.link(to: capture, at: seconds) ?? capture.url
    }

    /// The source's name for a kind, or the kind itself for one no provider reads any more.
    public func name(for kind: SourceKind) -> String { provider(for: kind)?.name ?? kind.rawValue.capitalized }

    /// The names of every source, in order: "YouTube and Pinterest".
    public var names: [String] { providers.map(\.name) }

    /// The provider whose short link this is, before any request.
    public func shortLinkProvider(for url: URL) -> (any SourceProvider)? {
        providers.first { $0.isShortLink(url) }
    }

    /// The item's own link: a short link is followed with one request, anything else comes back unchanged.
    public func expand(_ url: URL) async throws -> URL {
        guard match(url) == nil, let provider = shortLinkProvider(for: url) else { return url }
        return try await provider.expand(url)
    }

    public func match(_ url: URL) -> (provider: any SourceProvider, entryID: String)? {
        for provider in providers {
            if let id = provider.identify(url) { return (provider, "\(provider.kind.rawValue):\(id)") }
        }
        return nil
    }

    /// Finds every supported link in free text (a pasted list, a note, a chat message), in order, deduplicated.
    /// Short links count too; two short links to the same item are only told apart once they are expanded.
    public func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var seen = Set<String>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let url = match.url else { return nil }
            let key = self.match(url)?.entryID ?? (shortLinkProvider(for: url) != nil ? url.absoluteString : nil)
            guard let key, seen.insert(key).inserted else { return nil }
            return url
        }
    }

    /// Whether Nab reads this link, as an item or as a short link to one.
    public func supports(_ url: URL) -> Bool { match(url) != nil || shortLinkProvider(for: url) != nil }
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
    /// Tasks waiting for a slot, first come first served; each is told whether it got one (false: it was cancelled).
    private var waiting: [(id: UUID, slot: CheckedContinuation<Bool, Never>)] = []

    public init(limit: Int) { self.limit = limit }

    /// Runs `work` once a slot is free. A task cancelled while it waits leaves the line at once and throws
    /// `CancellationError`, so a removed item never holds up the ones behind it.
    public func run<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        try await enter()
        defer { leave() }
        return try await work()
    }

    private func enter() async throws {
        guard running >= limit else {
            running += 1
            return
        }
        let id = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { slot in
                if Task.isCancelled { slot.resume(returning: false) } else { waiting.append((id, slot)) }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        guard admitted else { throw CancellationError() }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).slot.resume(returning: false)
    }

    /// Hands the slot to the next in line, or frees it.
    private func leave() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().slot.resume(returning: true) }
    }
}
