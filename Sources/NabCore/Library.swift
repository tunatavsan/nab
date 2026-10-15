import CryptoKit
import Foundation

/// One link in the library and how far Nab got with it.
public struct Entry: Codable, Sendable, Hashable, Identifiable {
    public enum Phase: Sendable { case fetching, ready, failed }

    public let id: String
    public var url: URL
    public var addedAt: Date
    /// Title known before the fetch finishes (from the browser tab), replaced by the capture's.
    public var provisionalTitle: String?
    public var capture: Capture?
    public var failure: String?
    /// In the tray: the working set of recent captures that "Copy context" packs. Clearing the tray
    /// keeps entries in the library.
    public var inTray: Bool
    /// The capture session this entry was nabbed in; nil for entries saved before sessions existed.
    public var sessionID: String?

    public init(id: String, url: URL, addedAt: Date = .now, provisionalTitle: String? = nil, inTray: Bool = true) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
        self.provisionalTitle = provisionalTitle
        self.inTray = inTray
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        provisionalTitle = try c.decodeIfPresent(String.self, forKey: .provisionalTitle)
        capture = try c.decodeIfPresent(Capture.self, forKey: .capture)
        failure = try c.decodeIfPresent(String.self, forKey: .failure)
        inTray = try c.decodeIfPresent(Bool.self, forKey: .inTray) ?? false
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
    }

    /// The source and the id inside it, read from the entry id (`<source>:<id>`) so they are known before
    /// the fetch finishes.
    public var source: SourceKind { SourceKind(rawValue: String(id.prefix { $0 != ":" })) }
    public var sourceID: String { String(id.drop { $0 != ":" }.dropFirst()) }

    public var phase: Phase { capture != nil ? .ready : failure != nil ? .failed : .fetching }
    public var title: String { capture?.title ?? provisionalTitle ?? url.absoluteString }
}

/// The library on disk: one JSON file per entry, so saving a capture never rewrites the others.
public actor LibraryStore {
    public let folder: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// `~/Library/Application Support/Nab/Library`, or `$NAB_DATA_DIR/Library` for demos and experiments that should
    /// not touch the real library.
    public static var defaultFolder: URL {
        let data =
            ProcessInfo.processInfo.environment["NAB_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.applicationSupportDirectory.appending(path: "Nab", directoryHint: .isDirectory)
        return data.appending(path: "Library", directoryHint: .isDirectory)
    }

    public init(folder: URL = LibraryStore.defaultFolder) {
        self.folder = folder
    }

    public func loadAll() -> [Entry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { file in
                do {
                    return try decoder.decode(Entry.self, from: Data(contentsOf: file))
                } catch {
                    // Left on disk untouched, so a newer version or the user can still recover it.
                    NSLog("Nab: skipped unreadable \(file.lastPathComponent): \(error)")
                    return nil
                }
            }
            .sorted { $0.addedAt > $1.addedAt }
    }

    public func save(_ entry: Entry) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try encoder.encode(entry).write(to: file(for: entry.id), options: .atomic)
    }

    public func delete(_ id: String) throws {
        try Self.remove(file(for: id))
    }

    /// Removes a file; one that is already gone is not an error.
    static func remove(_ file: URL) throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch CocoaError.fileNoSuchFile {
        }
    }

    private func file(for id: String) -> URL {
        folder.appending(path: Self.fileName(for: id))
    }

    /// A file name for an id: readable when the id is short, a SHA-256 digest when it is not. A set of videos
    /// chatted about together has an id that grows with every video, and cutting it short would let two sets
    /// share one file.
    static func fileName(for id: String) -> String {
        let readable = String(id.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        guard readable.count > 120 else { return readable + ".json" }
        let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
        return String(readable.prefix(40)) + "-" + digest + ".json"
    }
}
