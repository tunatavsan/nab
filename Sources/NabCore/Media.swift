import Foundation

/// Where photos and clips are saved.
public enum MediaFolder {
    /// The user's choice, an absolute path in UserDefaults.
    public static let key = "media.folder"

    /// The user's folder when they chose one; otherwise `$NAB_DATA_DIR/Media` for a run on its own data folder (so a
    /// demo or a test never writes to the user's Downloads), otherwise `~/Downloads/Nab`.
    public static func resolve(
        setting: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
        downloads: URL = .downloadsDirectory
    ) -> URL {
        if let setting, setting.hasPrefix("/") { return URL(filePath: setting, directoryHint: .isDirectory) }
        if let data = environment["NAB_DATA_DIR"], !data.isEmpty {
            return URL(filePath: data, directoryHint: .isDirectory).appending(
                path: "Media", directoryHint: .isDirectory)
        }
        return downloads.appending(path: "Nab", directoryHint: .isDirectory)
    }

    /// Half-moved files Nab left in `folder`: `….partial` under one of Nab's own names (`Title (Pinterest 123).png
    /// .partial`). A transfer arrives in the system's temporary folder and is a `.partial` here only between its move
    /// and its rename, so one is left only when Nab quit right then. Anything else in the folder is never touched.
    public static func leftovers(
        in folder: URL, sourceNames: [String], fileManager: FileManager = .default
    ) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        return
            names
            .filter { name in
                name.hasSuffix(".partial") && sourceNames.contains { name.contains(" (\($0) ") }
            }
            .sorted()
            .map { folder.appending(path: $0) }
    }
}

/// File names a person can read that still say where the file came from: `Title (Pinterest 123).png`, and
/// `Title (Pinterest 123) 2.mp4` for the second page of a pin with several.
public enum MediaFileName {
    public static let maxCharacters = 100
    /// File systems count bytes; 240 leaves room for the `.partial` suffix inside the usual 255.
    static let maxBytes = 240

    public static func make(title: String, source: String, id: String, page: Int?, ext: String) -> String {
        let suffix = " (\(clean(source)) \(clean(id)))" + (page.map { " \($0)" } ?? "") + "." + ext
        var head = clean(title)
        while !head.isEmpty
            && (head.count + suffix.count > maxCharacters || head.utf8.count + suffix.utf8.count > maxBytes)
        {
            head = String(head.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        let name = head.isEmpty ? String(suffix.dropFirst()) : head + suffix
        guard name.count > maxCharacters || name.utf8.count > maxBytes else { return name }
        // Only an absurd id gets here; keep the extension so the file still opens.
        var cut = String(name.dropLast(ext.count + 1))
        while cut.count + ext.count + 1 > maxCharacters || cut.utf8.count + ext.utf8.count + 1 > maxBytes {
            cut.removeLast()
        }
        return cut + "." + ext
    }

    /// The extension of the copy the source chose, when it is a plain one; else one that fits the kind.
    public static func ext(for media: Media) -> String {
        let ext = media.url.pathExtension.lowercased()
        if (1...5).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) { return ext }
        return media.kind == .video ? "mp4" : "jpg"
    }

    /// The names of every file of a capture, in order; pages are numbered only when there is more than one.
    public static func names(for capture: Capture, sourceName: String) -> [String] {
        capture.media.enumerated().map { index, media in
            make(
                title: capture.title, source: sourceName, id: capture.sourceID,
                page: capture.media.count > 1 ? index + 1 : nil, ext: ext(for: media))
        }
    }

    /// No path separators, no colons (Finder shows them as slashes), no control characters, no leading dots (a
    /// hidden file), one space between words.
    static func clean(_ text: String) -> String {
        let mapped = text.map { c -> Character in
            if c == "/" || c == ":" || c == "\\" { return "-" }
            if c.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) || c.isNewline {
                return " "
            }
            return c
        }
        let words = String(mapped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.drop { $0 == "." || $0 == " " })
    }
}

/// A server answered with an error status; providers fall back to a smaller copy on some of them.
public struct HTTPStatusError: LocalizedError, Sendable, Equatable {
    public let status: Int
    public init(status: Int) { self.status = status }
    public var errorDescription: String? { "The server refused the download (HTTP \(status))." }
}

/// Streams photos and clips to disk. It has its own gate and its own connections, so a large clip never holds up
/// the details of the next link.
public final class MediaDownloader: Sendable {
    public static let shared = MediaDownloader()

    private let session: URLSession
    private let gate: Gate
    private let attempts: Int
    private let backoff: Duration
    /// Runs while a finished transfer sits as `.partial` next to its target, just before the rename; tests use it to
    /// stop a download at that point.
    private let beforeRename: @Sendable () async -> Void

    public convenience init(
        session: URLSession = .nabMedia, limit: Int = 6, attempts: Int = 3, backoff: Duration = .milliseconds(800)
    ) {
        self.init(session: session, limit: limit, attempts: attempts, backoff: backoff, beforeRename: {})
    }

    init(
        session: URLSession, limit: Int, attempts: Int, backoff: Duration,
        beforeRename: @escaping @Sendable () async -> Void
    ) {
        self.session = session
        gate = Gate(limit: limit)
        self.attempts = attempts
        self.backoff = backoff
        self.beforeRename = beforeRename
    }

    /// Writes `url` to `file` and returns its size. The transfer goes to a temporary file, then to `<file>.partial`
    /// next to the target, and takes the real name in one rename, so a half-written file never sits under it. The
    /// rename refuses a name that is already taken: a file Nab did not just write is never replaced.
    /// 429 and 503 are retried after a growing wait (`attempts` tries in all), waited out without holding a slot.
    /// Cancelling the calling task stops the transfer and leaves no partial file behind.
    @discardableResult
    public func download(
        _ url: URL, to file: URL, headers: [String: String] = [:],
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void = { _, _ in }
    ) async throws -> Int64 {
        var attempt = 1
        while true {
            do {
                return try await gate.run { try await transfer(url, to: file, headers: headers, progress: progress) }
            } catch let error as HTTPStatusError where [429, 503].contains(error.status) && attempt < attempts {
                try await Task.sleep(for: backoff * (1 << (attempt - 1)))
                attempt += 1
            }
        }
    }

    private func transfer(
        _ url: URL, to file: URL, headers: [String: String],
        progress: @escaping @Sendable (_ received: Int64, _ expected: Int64?) -> Void
    ) async throws -> Int64 {
        var request = URLRequest(url: url)
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        let watcher = ProgressWatcher(progress)
        let (temporary, response) = try await session.download(for: request, delegate: watcher)
        watcher.stop()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPStatusError(status: http.statusCode)
        }
        try Task.checkCancellation()
        let partial = Self.partialFile(for: file)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try? fm.removeItem(at: partial)
            try fm.moveItem(at: temporary, to: partial)
            await beforeRename()
            try Task.checkCancellation()
            try Self.claim(file, from: partial)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        progress(size, size)
        return size
    }

    /// Gives `partial` the name `file` in one step, and refuses when anything is already there (`RENAME_EXCL`). A
    /// volume that cannot refuse in the same step gets a move, which refuses a taken name too.
    static func claim(_ file: URL, from partial: URL) throws {
        if renamex_np(partial.path, file.path, UInt32(RENAME_EXCL)) == 0 { return }
        switch errno {
        case EEXIST: throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: file.path])
        case ENOTSUP: try FileManager.default.moveItem(at: partial, to: file)
        default: throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
    }

    /// `photo.png.partial`: the name a file has while it is still arriving.
    public static func partialFile(for file: URL) -> URL { file.appendingPathExtension("partial") }
}

/// Reports a download's bytes as they arrive, at most once per percent.
private final class ProgressWatcher: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Int64, Int64?) -> Void
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private var last = -1.0

    init(_ report: @escaping @Sendable (Int64, Int64?) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        let observation = task.progress.observe(\.fractionCompleted) { [weak self, weak task] progress, _ in
            guard let task else { return }
            self?.update(
                progress.fractionCompleted, received: task.countOfBytesReceived,
                expected: task.countOfBytesExpectedToReceive)
        }
        lock.withLock { self.observation = observation }
    }

    private func update(_ fraction: Double, received: Int64, expected: Int64) {
        let send = lock.withLock {
            guard fraction - last >= 0.01, fraction < 1 else { return false }
            last = fraction
            return true
        }
        if send { report(received, expected > 0 ? expected : nil) }
    }

    func stop() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
        }
    }
}

extension URLSession {
    /// The downloader's own pool, apart from the one that fetches details.
    public static let nabMedia: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 6
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
}
