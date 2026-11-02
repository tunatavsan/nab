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
    /// The photos and clips this item is made of, in order, once the source has picked the best copy of each.
    /// Empty for a video read as a transcript.
    public var media: [Media]
    /// One line about what could not be saved ("2 of 5 clips can't be saved"), shown with the item's kind line.
    public var note: String?
    /// A summary written by the user's chosen AI model, and which model wrote it.
    public var aiSummary: String?
    public var aiModel: String?

    public init(
        source: SourceKind, sourceID: String, url: URL, title: String, author: String? = nil,
        authorURL: URL? = nil, duration: TimeInterval? = nil, viewCount: Int? = nil, summary: String? = nil,
        keywords: [String] = [], thumbnailURL: URL? = nil, chapters: [Chapter] = [], transcript: Transcript? = nil,
        media: [Media] = [], note: String? = nil
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
        self.media = media
        self.note = note
    }

    /// Written by hand only so files saved before `media` existed still open: a missing list is an empty one.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(SourceKind.self, forKey: .source)
        sourceID = try c.decode(String.self, forKey: .sourceID)
        url = try c.decode(URL.self, forKey: .url)
        title = try c.decode(String.self, forKey: .title)
        author = try c.decodeIfPresent(String.self, forKey: .author)
        authorURL = try c.decodeIfPresent(URL.self, forKey: .authorURL)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        keywords = try c.decode([String].self, forKey: .keywords)
        thumbnailURL = try c.decodeIfPresent(URL.self, forKey: .thumbnailURL)
        chapters = try c.decode([Chapter].self, forKey: .chapters)
        transcript = try c.decodeIfPresent(Transcript.self, forKey: .transcript)
        // A photo or clip of a kind this version does not know (written by a newer one) is skipped, not the item.
        media = try c.decodeIfPresent([Lossy<Media>].self, forKey: .media)?.compactMap(\.value) ?? []
        note = try c.decodeIfPresent(String.self, forKey: .note)
        aiSummary = try c.decodeIfPresent(String.self, forKey: .aiSummary)
        aiModel = try c.decodeIfPresent(String.self, forKey: .aiModel)
    }

    /// A media item: its photos and clips are what the user keeps. A text item: its transcript is.
    /// The interface asks these, never the source.
    public var isMedia: Bool { !media.isEmpty }

    /// Neither a transcript nor photos and clips: nothing to keep. A pin saved by this version and then opened by an
    /// older one loses its list of files that way, so nabbing it again reads it again (and finds its files, still in
    /// the folder under its name). A video without captions is read again too, which picks up captions added since.
    public var holdsNothing: Bool { transcript == nil && media.isEmpty }
}

/// Decodes a value or nothing, so one unreadable element does not fail the list around it.
struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: any Decoder) throws { value = try? Value(from: decoder) }
}

/// One photo or clip of an item: where the source's best copy lives and, once Nab has saved it, where it is on disk.
public struct Media: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case image, video }

    public var kind: Kind
    /// The best copy the source offers.
    public var url: URL
    public var width: Int?
    public var height: Int?
    public var duration: TimeInterval?
    /// The absolute path of the saved file; nil until it is saved.
    public var savedPath: String?
    public var byteCount: Int64?

    public init(
        kind: Kind, url: URL, width: Int? = nil, height: Int? = nil, duration: TimeInterval? = nil,
        savedPath: String? = nil, byteCount: Int64? = nil
    ) {
        self.kind = kind
        self.url = url
        self.width = width
        self.height = height
        self.duration = duration
        self.savedPath = savedPath
        self.byteCount = byteCount
    }

    public var savedURL: URL? { savedPath.map { URL(filePath: $0) } }

    /// Whether the file at this item's saved path, `size` bytes (nil: no file there), is still there to use. A file
    /// the user edited since is theirs and is used as it is; only an absent or empty one is gone.
    public static func isPresent(size: Int64?) -> Bool { (size ?? 0) > 0 }

    /// Whether a file of `size` bytes found under this item's name, with no saved path to go by, can be taken as the
    /// copy saved before: the size it was saved at, or any size above zero when that was not recorded. A file cut
    /// short is not taken.
    static func isIntact(size: Int64?, expected: Int64?) -> Bool {
        guard let size, size > 0 else { return false }
        return expected.map { $0 == size } ?? true
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

extension TimeInterval {
    /// Whole seconds for display and links. Non-finite values count as 0 and huge ones are clamped, because
    /// `Int(_:)` traps on both and times can arrive from outside (a `nab-cite://` link).
    public var wholeSeconds: Int {
        guard isFinite else { return 0 }
        return Int(min(max(self, 0), 1e12).rounded(.down))
    }
}

public enum Timecode {
    /// `1:02:03` or `4:05`.
    public static func string(_ seconds: TimeInterval) -> String {
        let total = seconds.wholeSeconds
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
