import Foundation
import NabCore
import NabPinterest
import NabYouTube
import Testing

@testable import NabAI

/// Fetches a real talk and asks the default provider (Claude Code) for a summary, then a follow-up.
/// Run with `NAB_LIVE=1 swift test --filter LiveTests`.
@Suite("Live", .enabled(if: ProcessInfo.processInfo.environment["NAB_LIVE"] != nil), .timeLimit(.minutes(3)))
struct LiveTests {
    @Test func summaryAndFollowUp() async throws {
        let capture = try await YouTubeSource().fetch(URL(string: "https://www.youtube.com/watch?v=8jPQjjsBbIc")!)
        let settings = AISettings()
        let client = AIClient(settings: settings, apiKey: nil)
        let context = ChatContext.pack([capture])

        var turns = [ChatMessage(role: .user, text: settings.resolvedSummaryPrompt, isSummaryRequest: true)]
        let summary = try await collect(client.reply(context: context, turns: turns))
        print("SUMMARY:\n\(summary)\n")
        #expect(summary.count > 200)
        #expect(Citation.link(summary).contains("nab-cite://"))

        turns.append(ChatMessage(role: .assistant, text: summary))
        turns.append(
            ChatMessage(role: .user, text: "What exactly is a pre-mortem, according to the talk? One short paragraph."))
        let answer = try await collect(client.reply(context: context, turns: turns))
        print("FOLLOW-UP:\n\(answer)\n")
        #expect(answer.count > 60)
    }
}

/// Counts the requests a session really sent, redirects included, from the transfer metrics.
private final class RequestCounter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var sent = 0
    private var lines: [String] = []
    var count: Int { lock.withLock { sent } }
    /// One line per request: method, status and address (the query is cut).
    var log: String { lock.withLock { lines.joined(separator: "\n") } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let fetched = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }.count
        let described = metrics.transactionMetrics.filter { $0.resourceFetchType == .networkLoad }.map { item in
            let status = (item.response as? HTTPURLResponse)?.statusCode ?? 0
            let address = item.request.url.map { "\($0.host() ?? "")\($0.path())" } ?? ""
            return "\(item.request.httpMethod ?? "GET") \(status) \(address)"
        }
        lock.withLock {
            sent += fetched
            lines += described
        }
    }
}

/// Fetches real pins and saves their media. The links come from `NAB_LIVE_PINS` (whitespace or comma separated),
/// the files go to `NAB_LIVE_OUT`, and a `results.tsv` next to them says what each link cost.
/// Run with `NAB_LIVE_PINS="https://…" NAB_LIVE_OUT=/some/folder swift test --filter LivePinterestTests`.
@Suite(
    "Live Pinterest", .enabled(if: ProcessInfo.processInfo.environment["NAB_LIVE_PINS"] != nil),
    .timeLimit(.minutes(10)))
struct LivePinterestTests {
    @Test func savesWhatEveryLinkHolds() async throws {
        let environment = ProcessInfo.processInfo.environment
        let links = (environment["NAB_LIVE_PINS"] ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," })
            .compactMap { URL(string: String($0)) }
        let out = URL(filePath: environment["NAB_LIVE_OUT"] ?? NSTemporaryDirectory(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let counter = RequestCounter()
        let config = URLSession.nab.configuration
        let details = URLSession(configuration: config, delegate: counter, delegateQueue: nil)
        let mediaSession = URLSession(
            configuration: URLSession.nabMedia.configuration, delegate: counter, delegateQueue: nil)
        let source = PinterestSource(session: details, downloader: MediaDownloader(session: mediaSession))

        func seconds(_ d: Duration) -> String {
            String(format: "%.2f", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        var rows = ["link\tkind\tmedia\tfile\tbytes\tfetch_s\tsave_s\trequests\tnote"]
        for link in links {
            let before = counter.count
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let capture = try await source.fetch(link)
                let fetched = clock.now - start
                let names = MediaFileName.names(for: capture, sourceName: source.name)
                let saveStart = clock.now
                var files: [(String, Int64, String)] = []
                for (media, name) in zip(capture.media, names) {
                    let file = out.appending(path: name)
                    try await source.save(media, of: capture, to: file, progress: { _, _ in })
                    let bytes =
                        (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
                        ?? 0
                    files.append((name, bytes, media.url.absoluteString))
                }
                let saved = clock.now - saveStart
                let kinds = Set(capture.media.map(\.kind.rawValue)).sorted().joined(separator: "+")
                for (name, bytes, url) in files {
                    rows.append(
                        [
                            link.absoluteString, kinds, "\(files.count)", name, "\(bytes)",
                            seconds(fetched),
                            seconds(saved),
                            "\(counter.count - before)", url,
                        ].joined(separator: "\t"))
                }
            } catch {
                rows.append(
                    [
                        link.absoluteString, "-", "0", "-", "0", "-", "-", "\(counter.count - before)",
                        "\(error.localizedDescription)",
                    ]
                    .joined(separator: "\t"))
            }
        }
        rows.append("TOTAL requests\t\(counter.count)")
        let table = rows.joined(separator: "\n")
        try table.write(to: out.appending(path: "results.tsv"), atomically: true, encoding: .utf8)
        try counter.log.write(to: out.appending(path: "requests.log"), atomically: true, encoding: .utf8)
        print(table)
        #expect(counter.count <= 120)
    }
}
