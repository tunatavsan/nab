import Foundation

public struct ChatMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: UUID
    public var role: Role
    public var text: String
    public var date: Date
    /// The model that wrote an assistant message.
    public var model: String?
    /// A user turn that asked for the summary; shown as a label, not as the long instruction.
    public var isSummaryRequest: Bool
    /// An assistant turn that ended in an error; its text is the error.
    public var failed: Bool

    public init(role: Role, text: String, model: String? = nil, isSummaryRequest: Bool = false, failed: Bool = false) {
        id = UUID()
        self.role = role
        self.text = text
        date = .now
        self.model = model
        self.isSummaryRequest = isSummaryRequest
        self.failed = failed
    }
}

/// A transcript moment an answer cites: `[12:40]`, or `[2 12:40]` for the second of several videos.
public struct Citation: Hashable, Sendable {
    public static let scheme = "nab-cite"

    /// 1-based position in the chat's videos; nil when the chat has one.
    public var video: Int?
    public var seconds: TimeInterval

    public init(video: Int?, seconds: TimeInterval) {
        self.video = video
        self.seconds = seconds
    }

    public init?(url: URL) {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard url.scheme == Self.scheme, parts.count == 2, let video = Int(parts[0]), let seconds = Double(parts[1])
        else { return nil }
        self.video = video == 0 ? nil : video
        self.seconds = seconds
    }

    public var url: URL { URL(string: "\(Self.scheme)://t/\(video ?? 0)/\(Int(seconds))")! }

    public static func seconds(_ timecode: Substring) -> TimeInterval? {
        let parts = timecode.split(separator: ":").compactMap { Int($0) }
        guard (2...3).contains(parts.count) else { return nil }
        return TimeInterval(parts.reduce(0) { $0 * 60 + $1 })
    }

    /// Rewrites bracketed timecodes as Markdown links before parsing. Ranges ("[3:10–4:02]") link to their start.
    public static func link(_ text: String) -> String {
        text.replacing(
            /\[(?:(\d{1,2})\s*[·,]?\s+)?(\d{1,2}(?::\d{2}){1,2})((?:\s*[–—-]\s*\d{1,2}(?::\d{2}){1,2})?)\](?!\()/
        ) { match in
            guard let seconds = seconds(match.output.2) else { return String(match.output.0) }
            let video = match.output.1.flatMap { Int($0) }
            let label = (video.map { "\($0) · " } ?? "") + match.output.2 + match.output.3
            return "[\(label)](\(Citation(video: video, seconds: seconds).url.absoluteString))"
        }
    }
}

/// A chat about a fixed set of library entries: one video, or several packed together.
public struct Conversation: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public var entryIDs: [String]
    public var messages: [ChatMessage]
    public var updatedAt: Date

    public init(entryIDs: [String]) {
        self.entryIDs = entryIDs
        id = Conversation.id(for: entryIDs)
        messages = []
        updatedAt = .now
    }

    /// Same entries, same chat, whatever order they were selected in.
    public static func id(for entryIDs: [String]) -> String {
        entryIDs.count == 1 ? entryIDs[0] : "pack:" + entryIDs.sorted().joined(separator: "+")
    }

    /// Turns that can be sent back to a model: failed answers and the question that caused them are dropped.
    public var sendable: [ChatMessage] {
        var result: [ChatMessage] = []
        for message in messages {
            if message.failed {
                if result.last?.role == .user { result.removeLast() }
                continue
            }
            result.append(message)
        }
        return result
    }
}

extension LibraryStore {
    public func conversation(_ id: String) -> Conversation? {
        guard let data = try? Data(contentsOf: chatFile(id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Conversation.self, from: data)
        } catch {
            NSLog("Nab: could not read chat \(id): \(error)")
            return nil
        }
    }

    public func save(_ conversation: Conversation) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: chatFolder, withIntermediateDirectories: true)
            try encoder.encode(conversation).write(to: chatFile(conversation.id), options: .atomic)
        } catch {
            NSLog("Nab: could not save chat: \(error.localizedDescription)")
        }
    }

    public func deleteConversation(_ id: String) {
        try? FileManager.default.removeItem(at: chatFile(id))
    }

    private var chatFolder: URL {
        folder.deletingLastPathComponent().appending(path: "Chats", directoryHint: .isDirectory)
    }

    private func chatFile(_ id: String) -> URL {
        chatFolder.appending(path: Self.fileName(for: id))
    }
}
