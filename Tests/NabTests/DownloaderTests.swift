import Foundation
import Testing

@testable import NabCore

/// Answers requests from a table instead of the network: a status and a body per path, or no answer at all.
final class MediaStub: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var body: Data
    }
    nonisolated(unsafe) private static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) private static var counts: [String: Int] = [:]
    private static let lock = NSLock()

    static func set(_ path: String, _ replies: [Reply]) { lock.withLock { self.replies[path] = replies } }
    static func count(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path() ?? ""
        let reply: Reply? = Self.lock.withLock {
            Self.counts[path, default: 0] += 1
            guard var list = Self.replies[path], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            if !list.isEmpty { Self.replies[path] = list }
            return first
        }
        guard let reply else { return }  // never answers: a stalled transfer
        let response = HTTPURLResponse(
            url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(reply.body.count)"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Progress reports as they arrive, from any thread.
final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [(Int64, Int64?)] = []
    func add(_ received: Int64, _ expected: Int64?) { lock.withLock { all.append((received, expected)) } }
    var last: (Int64, Int64?)? { lock.withLock { all.last } }
}

@Suite("Saving photos and clips")
struct DownloaderTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "nab-dl-\(UUID().uuidString)")

    func downloader() -> MediaDownloader {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStub.self]
        return MediaDownloader(session: URLSession(configuration: config), limit: 2, backoff: .milliseconds(1))
    }

    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    @Test func savesUnderTheRealNameOnlyWhenComplete() async throws {
        let body = Data((0..<200_000).map { UInt8($0 % 251) })
        MediaStub.set("/ok.png", [.init(status: 200, body: body)])
        let file = folder.appending(path: "Lamp (Pinterest 1).png")
        let reports = Reports()
        let size = try await downloader().download(URL(string: "https://media.example/ok.png")!, to: file) {
            reports.add($0, $1)
        }
        #expect(size == Int64(body.count))
        #expect(reports.last?.0 == size && reports.last?.1 == size)
        #expect(try Data(contentsOf: file) == body)
        #expect(leftovers() == ["Lamp (Pinterest 1).png"])
    }

    /// A name that is taken when the transfer ends is refused, not replaced: the file there keeps its bytes and no
    /// half file is left.
    @Test func aTakenNameIsNeverReplaced() async throws {
        MediaStub.set("/taken.png", [.init(status: 200, body: Data(repeating: 7, count: 64))])
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "taken.png")
        FileManager.default.createFile(atPath: file.path, contents: Data("mine".utf8))
        await #expect(throws: (any Error).self) {
            _ = try await downloader().download(URL(string: "https://media.example/taken.png")!, to: file)
        }
        #expect(try Data(contentsOf: file) == Data("mine".utf8))
        #expect(leftovers() == ["taken.png"])
    }

    @Test func refusalLeavesNothingAndSaysWhy() async throws {
        MediaStub.set("/gone.png", [.init(status: 403, body: Data("<Error/>".utf8))])
        let file = folder.appending(path: "x.png")
        await #expect(throws: HTTPStatusError(status: 403)) {
            _ = try await downloader().download(URL(string: "https://media.example/gone.png")!, to: file)
        }
        #expect(leftovers().isEmpty)
    }

    @Test func busyServersAreAskedAgainThenGivenUpOn() async throws {
        MediaStub.set("/busy.mp4", [.init(status: 429, body: Data()), .init(status: 200, body: Data("ok".utf8))])
        let file = folder.appending(path: "busy.mp4")
        _ = try await downloader().download(URL(string: "https://media.example/busy.mp4")!, to: file)
        #expect(MediaStub.count("/busy.mp4") == 2)
        MediaStub.set("/down.mp4", Array(repeating: .init(status: 503, body: Data()), count: 5))
        await #expect(throws: HTTPStatusError(status: 503)) {
            _ = try await downloader().download(
                URL(string: "https://media.example/down.mp4")!, to: folder.appending(path: "down.mp4"))
        }
        #expect(MediaStub.count("/down.mp4") == 3)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingStopsTheTransferAndLeavesNoPartialFile() async throws {
        let file = folder.appending(path: "stalled.mp4")
        let loader = downloader()
        let task = Task { try await loader.download(URL(string: "https://media.example/stalled.mp4")!, to: file) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(leftovers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: MediaDownloader.partialFile(for: file).path))
    }

    /// Stopped while the arrived file sits as `.partial` next to its target: the `.partial` goes, and the target
    /// name never holds it.
    @Test(.timeLimit(.minutes(1))) func cancellingBeforeTheRenameRemovesThePartialFile() async throws {
        MediaStub.set("/late.png", [.init(status: 200, body: Data(repeating: 7, count: 64))])
        let file = folder.appending(path: "late.png")
        let partial = MediaDownloader.partialFile(for: file)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MediaStub.self]
        let loader = MediaDownloader(
            session: URLSession(configuration: config), limit: 2, attempts: 1, backoff: .milliseconds(1),
            beforeRename: { try? await Task.sleep(for: .seconds(30)) })
        let task = Task { try await loader.download(URL(string: "https://media.example/late.png")!, to: file) }
        var waited = 0
        while !FileManager.default.fileExists(atPath: partial.path), waited < 300 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }
        #expect(FileManager.default.fileExists(atPath: partial.path))
        task.cancel()
        await #expect(throws: (any Error).self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}
