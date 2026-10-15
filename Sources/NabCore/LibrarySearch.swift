import Foundation

/// A piece of text, flagged when it matches the query; the palette draws matches in lime.
public struct HighlightPart: Hashable, Sendable {
    public let text: String
    public let isMatch: Bool
    public init(text: String, isMatch: Bool) {
        self.text = text
        self.isMatch = isMatch
    }
}

public struct VideoHit: Identifiable, Hashable, Sendable {
    public var id: String { entryID }
    public let entryID: String
    public let title: [HighlightPart]
    public let author: String?
}

public struct ChatHit: Identifiable, Hashable, Sendable {
    public var id: String { chat.id }
    public let chat: ChatPreview
    public let title: [HighlightPart]
}

public struct TranscriptHit: Identifiable, Hashable, Sendable {
    public var id: String { "\(entryID)@\(seconds.wholeSeconds)" }
    public let entryID: String
    public let seconds: TimeInterval
    public let snippet: [HighlightPart]
    public let videoTitle: String
}

public struct SearchResults: Hashable, Sendable {
    public var videos: [VideoHit] = []
    public var chats: [ChatHit] = []
    public var transcripts: [TranscriptHit] = []
    /// Matching transcript lines before the limits, for "In transcripts · 14 lines".
    public var transcriptTotal = 0
    public var isEmpty: Bool { videos.isEmpty && chats.isEmpty && transcripts.isEmpty }
    public init() {}
}

public enum LibrarySearch {
    public static let maxVideos = 6
    public static let maxChats = 4
    public static let maxPerVideo = 3
    public static let maxTranscriptHits = 12
    /// Lines closer than this in one video count as one hit.
    public static let hitGap: TimeInterval = 10

    /// Words of a query; every word must appear for something to match.
    public static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private static let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    public static func matches(_ text: String, terms: [String]) -> Bool {
        !terms.isEmpty && terms.allSatisfy { text.range(of: $0, options: options) != nil }
    }

    /// Splits `text` so that every occurrence of a term is a match part, in order and without overlap.
    public static func highlight(_ text: String, terms: [String]) -> [HighlightPart] {
        var ranges: [Range<String.Index>] = []
        for term in terms where !term.isEmpty {
            var from = text.startIndex
            while from < text.endIndex, let r = text.range(of: term, options: options, range: from..<text.endIndex) {
                ranges.append(r)
                from = r.upperBound
            }
        }
        ranges.sort { $0.lowerBound < $1.lowerBound }
        var merged: [Range<String.Index>] = []
        for r in ranges {
            if let last = merged.last, r.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                merged.append(r)
            }
        }
        var parts: [HighlightPart] = []
        var cursor = text.startIndex
        for r in merged {
            if cursor < r.lowerBound {
                parts.append(HighlightPart(text: String(text[cursor..<r.lowerBound]), isMatch: false))
            }
            parts.append(HighlightPart(text: String(text[r]), isMatch: true))
            cursor = r.upperBound
        }
        if cursor < text.endIndex { parts.append(HighlightPart(text: String(text[cursor...]), isMatch: false)) }
        return parts
    }

    /// Searches video titles and authors, chat titles and transcript lines. `entries` and `chats` are newest
    /// first and keep that order within each group; a title match ranks above an author-only match. An empty
    /// query returns the most recent videos and chats.
    public static func search(_ query: String, entries: [Entry], chats: [Conversation]) -> SearchResults {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let previews = chats.filter { !$0.messages.isEmpty }.map { chat in
            ChatPreview(chat, titleOf: { byID[$0]?.title })
        }
        return search(query, entries: entries, previews: previews)
    }

    /// Same, over previews that are already built (see `ChatPreviewCache`). Everything it takes is a value, so it
    /// can run off the main thread; a cancelled task stops it between videos and returns what it has.
    public static func search(_ query: String, entries: [Entry], previews: [ChatPreview]) -> SearchResults {
        let words = terms(query)
        var result = SearchResults()
        guard !words.isEmpty else {
            result.videos = entries.prefix(maxVideos).map {
                VideoHit(
                    entryID: $0.id, title: [HighlightPart(text: $0.title, isMatch: false)], author: $0.capture?.author)
            }
            result.chats = previews.prefix(maxChats).map {
                ChatHit(chat: $0, title: [HighlightPart(text: $0.title, isMatch: false)])
            }
            return result
        }
        var byTitle: [VideoHit] = []
        var byAuthor: [VideoHit] = []
        for entry in entries {
            let author = entry.capture?.author
            if matches(entry.title, terms: words) {
                byTitle.append(VideoHit(entryID: entry.id, title: highlight(entry.title, terms: words), author: author))
            } else if let author, matches(author, terms: words) {
                byAuthor.append(
                    VideoHit(
                        entryID: entry.id, title: [HighlightPart(text: entry.title, isMatch: false)], author: author))
            }
        }
        result.videos = Array((byTitle + byAuthor).prefix(maxVideos))
        result.chats = previews.filter { matches($0.title, terms: words) }.prefix(maxChats).map {
            ChatHit(chat: $0, title: highlight($0.title, terms: words))
        }
        var hits: [TranscriptHit] = []
        for entry in entries {
            if Task.isCancelled { break }
            guard let segments = entry.capture?.transcript?.segments else { continue }
            var last: TimeInterval?
            for segment in segments where matches(segment.text, terms: words) {
                if let previous = last, segment.start - previous < hitGap { continue }
                last = segment.start
                result.transcriptTotal += 1
                let kept = hits.filter { $0.entryID == entry.id }.count
                guard kept < maxPerVideo, hits.count < maxTranscriptHits else { continue }
                let text = segment.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                hits.append(
                    TranscriptHit(
                        entryID: entry.id, seconds: segment.start, snippet: highlight(text, terms: words),
                        videoTitle: entry.title))
            }
        }
        result.transcripts = hits
        return result
    }
}
