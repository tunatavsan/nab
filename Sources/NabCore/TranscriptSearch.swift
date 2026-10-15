import Foundation

/// One hit of a find in a transcript.
public struct TranscriptMatch: Hashable, Sendable {
    /// Index into the paragraphs that were searched.
    public let paragraph: Int
    /// Where the hit starts and how long it is, in characters of that paragraph's text.
    public let offset: Int
    public let length: Int
    /// Start of the paragraph, in seconds.
    public let time: TimeInterval
    /// Index into the chapters, nil before the first one.
    public let chapter: Int?
}

/// Find in a transcript: every hit with its place, per-chapter counts and next/previous with wrap-around.
/// Case and diacritics do not matter, so "cay" finds "Çay".
public struct TranscriptSearch: Sendable {
    public let query: String
    public let matches: [TranscriptMatch]
    private let byParagraph: [Int: [Int]]
    private let perChapter: [Int: Int]

    public init(paragraphs: [Paragraph], chapters: [Chapter] = [], query: String) {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = needle
        var found: [TranscriptMatch] = []
        if !needle.isEmpty {
            for (index, paragraph) in paragraphs.enumerated() {
                let text = paragraph.text
                var from = text.startIndex
                while from < text.endIndex,
                    let range = text.range(
                        of: needle, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex)
                {
                    found.append(
                        TranscriptMatch(
                            paragraph: index, offset: text.distance(from: text.startIndex, to: range.lowerBound),
                            length: text.distance(from: range.lowerBound, to: range.upperBound),
                            time: paragraph.start, chapter: Self.chapterIndex(at: paragraph.start, in: chapters)))
                    from = range.upperBound
                }
            }
        }
        matches = found
        var grouped: [Int: [Int]] = [:]
        var counts: [Int: Int] = [:]
        for (index, match) in found.enumerated() {
            grouped[match.paragraph, default: []].append(index)
            if let chapter = match.chapter { counts[chapter, default: 0] += 1 }
        }
        byParagraph = grouped
        perChapter = counts
    }

    public var isActive: Bool { !query.isEmpty }

    /// The hits inside one paragraph, with their position in `matches`.
    public func matches(inParagraph paragraph: Int) -> [(index: Int, match: TranscriptMatch)] {
        (byParagraph[paragraph] ?? []).map { ($0, matches[$0]) }
    }

    public func count(inChapter chapter: Int) -> Int { perChapter[chapter] ?? 0 }

    /// The hit after `current` (the first when nothing is current), wrapping at the end. Nil without hits.
    public func index(after current: Int?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let current else { return 0 }
        return (current + 1) % matches.count
    }

    /// The hit before `current` (the last when nothing is current), wrapping at the start.
    public func index(before current: Int?) -> Int? {
        guard !matches.isEmpty else { return nil }
        guard let current else { return matches.count - 1 }
        return (current - 1 + matches.count) % matches.count
    }

    /// The chapter a moment falls in: the last one that has started.
    public static func chapterIndex(at seconds: TimeInterval, in chapters: [Chapter]) -> Int? {
        chapters.lastIndex { $0.start <= seconds + 0.5 }
    }
}
