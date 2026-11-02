import Foundation

extension URLSession {
    /// One shared session for details: keeps connections to a source warm across a batch.
    public static let nab: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 15
        config.httpAdditionalHeaders = ["Accept-Language": "en"]
        return URLSession(configuration: config)
    }()

    /// A second pool, so a hedged retry never waits behind the connection that stalled.
    public static let nabHedge: URLSession = URLSession(configuration: nab.configuration)

    /// Both of YouTube's requests usually answer in 0.2–0.4 s, but now and then one stalls for ~10 s (measured
    /// 2026-10-11, in the CLI and the app alike). If no answer has come after `delay`, the same request goes out
    /// again on a fresh connection and whichever answers first wins. The 450 ms default sits above the normal
    /// answer time and below the stalls (2026-10-15: timedtext p50 0.24 s, and 4 of 20 cold requests stalled
    /// 1.3–10.3 s; player max 0.37 s), so a healthy request is rarely doubled. Any source may use it.
    public func hedgedData(
        for request: URLRequest, delay: Duration = .milliseconds(450), silence: String
    ) async throws -> (Data, URLResponse) {
        let session = self
        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask { try await session.data(for: request) }
            group.addTask {
                try await Task.sleep(for: delay)
                return try await URLSession.nabHedge.data(for: request)
            }
            defer { group.cancelAll() }
            var lastError: Error = NabError(silence)
            for _ in 0..<2 {
                do {
                    if let result = try await group.next() { return result }
                } catch is CancellationError {
                    continue
                } catch {
                    lastError = error
                }
            }
            throw lastError
        }
    }
}
