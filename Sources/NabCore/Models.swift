import Foundation

/// A family of links Nab knows how to read. A new source adds a value here and a `SourceProvider`; the library,
/// the context pack and the chat handle it without changes.
public struct SourceKind: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let youtube = SourceKind(rawValue: "youtube")
}

/// Everything Nab extracted from one link.
public struct Capture: Codable, Sendable, Hashable {
    public var source: SourceKind
    /// Stable identifier inside the source, e.g. a YouTube video id.
    public var sourceID: String
    public var url: URL
    public var title: String
    public var author: String?
    public var authorURL: URL?
    public var duration: TimeInterval?
    public var viewCount: Int?
    public var summary: String?
    public var keywords: [String]
    public var thumbnailURL: URL?
    public var chapters: [Chapter]
    public var transcript: Transcript?
    /// A summary written by the user's chosen AI model, and which model wrote it.
    public var aiSummary: String?
    public var aiModel: String?

    public init(
        source: SourceKind, sourceID: String, url: URL, title: String, author: String? = nil,
        authorURL: URL? = nil, duration: TimeInterval? = nil, viewCount: Int? = nil, summary: String? = nil,
        keywords: [String] = [], thumbnailURL: URL? = nil, chapters: [Chapter] = [], transcript: Transcript? = nil
    ) {
        self.source = source
        self.sourceID = sourceID
        self.url = url
        self.title = title
        self.author = author
        self.authorURL = authorURL
        self.duration = duration
        self.viewCount = viewCount
        self.summary = summary
        self.keywords = keywords
        self.thumbnailURL = thumbnailURL
        self.chapters = chapters
        self.transcript = transcript
    }

    /// A link that opens the source at a moment, when the source supports it.
    public func url(at seconds: TimeInterval) -> URL {
        guard source == .youtube, var parts = URLComponents(string: "https://www.youtube.com/watch") else { return url }
        parts.queryItems = [.init(name: "v", value: sourceID), .init(name: "t", value: "\(Int(seconds))s")]
        return parts.url ?? url
    }
}

public struct Chapter: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var title: String
    public init(start: TimeInterval, title: String) {
        self.start = start
        self.title = title
    }
}

public struct Transcript: Codable, Sendable, Hashable {
    public var languageCode: String
    public var languageName: String?
    public var isGenerated: Bool
    public var segments: [Segment]

    public init(languageCode: String, languageName: String?, isGenerated: Bool, segments: [Segment]) {
        self.languageCode = languageCode
        self.languageName = languageName
        self.isGenerated = isGenerated
        self.segments = segments
    }

    public var wordCount: Int {
        segments.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
}

public struct Segment: Codable, Sendable, Hashable {
    public var start: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public init(start: TimeInterval, duration: TimeInterval, text: String) {
        self.start = start
        self.duration = duration
        self.text = text
    }
}

/// A transcript passage that starts at one timecode. Readers and context packs share this grouping
/// so a timecode quoted by an AI points at the same passage the user sees.
public struct Paragraph: Sendable, Hashable, Identifiable {
    public var start: TimeInterval
    public var text: String
    public var chapter: String?
    public var id: TimeInterval { start }
}

extension Transcript {
    /// Groups segments into passages: a new passage starts at every chapter, or once `window`
    /// seconds have passed and a sentence ends (hard cap at 1.6 × window for unpunctuated captions).
    public func paragraphs(chapters: [Chapter] = [], window: TimeInterval = 45) -> [Paragraph] {
        var result: [Paragraph] = []
        var current: Paragraph?
        var words: [String] = []
        var chapterIndex = -1

        func flush() {
            guard var paragraph = current, !words.isEmpty else { return }
            paragraph.text = words.joined(separator: " ")
            result.append(paragraph)
            current = nil
            words = []
        }

        for segment in segments {
            var newChapter: String?
            while chapterIndex + 1 < chapters.count, chapters[chapterIndex + 1].start <= segment.start + 0.5 {
                chapterIndex += 1
                newChapter = chapters[chapterIndex].title
            }
            if let open = current {
                let elapsed = segment.start - open.start
                let sentenceEnded =
                    words.last.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") } ?? false
                if newChapter != nil || (elapsed >= window && sentenceEnded) || elapsed >= window * 1.6 { flush() }
            }
            if current == nil {
                current = Paragraph(start: segment.start, text: "", chapter: newChapter)
            }
            words.append(segment.text)
        }
        flush()
        return result
    }
}

public enum Timecode {
    /// `1:02:03` or `4:05`.
    public static func string(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
