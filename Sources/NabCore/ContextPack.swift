import Foundation

/// Turns captures into one block of text an AI model reads well: XML tags mark where each source
/// starts and ends, Markdown carries the structure inside, and every passage keeps its timecode so
/// answers can cite a moment.
public enum ContextPack {
    public static func render(_ captures: [Capture], capturedAt: Date = .now) -> String {
        var out = "<nab_context sources=\"\(captures.count)\" packed=\"\(isoDay(capturedAt))\">\n"
        if captures.count > 1 {
            out += "Index:\n"
            for (i, c) in captures.enumerated() {
                out +=
                    "\(i + 1). \(inert(c.title))\(c.author.map { " — \(inert($0))" } ?? "")\(c.duration.map { " (\(Timecode.string($0)))" } ?? "")\n"
            }
            out += "\n"
        }
        out += captures.map(source).joined(separator: "\n")
        out += "</nab_context>\n"
        return out
    }

    public static func source(_ c: Capture) -> String {
        var out = "<source type=\"\(c.source.rawValue)\" id=\"\(c.sourceID)\" url=\"\(c.url.absoluteString)\">\n"
        out += "# \(inert(c.title))\n\n"
        if let cover = c.thumbnailURL { out += "![Cover](\(cover.absoluteString))\n\n" }
        var facts: [String] = []
        if let author = c.author { facts.append("Channel: \(inert(author))") }
        if let duration = c.duration { facts.append("Duration: \(Timecode.string(duration))") }
        if let views = c.viewCount { facts.append("Views: \(views.formatted())") }
        if let t = c.transcript {
            facts.append("Transcript: \(t.languageName ?? t.languageCode)\(t.isGenerated ? ", auto-generated" : "")")
        } else {
            facts.append("Transcript: none available")
        }
        out += facts.map { "- \($0)" }.joined(separator: "\n") + "\n"

        if let ai = c.aiSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !ai.isEmpty {
            out += "\n## Summary\(c.aiModel.map { " (by \(inert($0)))" } ?? "")\n\(inert(ai))\n"
        }
        if !c.chapters.isEmpty {
            out += "\n## Chapters\n"
            out += c.chapters.map { "[\(Timecode.string($0.start))] \(inert($0.title))" }.joined(separator: "\n") + "\n"
        }
        if let summary = c.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty {
            out += "\n## Description\n\(inert(summary))\n"
        }
        if let transcript = c.transcript {
            out += "\n## Transcript\n"
            var lastChapter: String?
            for p in transcript.paragraphs(chapters: c.chapters) {
                if let chapter = p.chapter, chapter != lastChapter {
                    out += "\n### \(inert(chapter))\n"
                    lastChapter = chapter
                }
                out += "[\(Timecode.string(p.start))] \(inert(p.text))\n"
            }
        }
        out += "</source>\n"
        return out
    }

    /// Text that comes from a video (title, description, captions, an earlier answer) cannot open or close the
    /// tags that frame it, so it cannot pose as another source or end the pack early.
    static func inert(_ text: String) -> String {
        text.replacing(#/<(/?)(source|nab_context)\b/#.ignoresCase()) { "&lt;\($0.output.1)\($0.output.2)" }
    }

    /// Rough size for display; models differ, so it is labelled as an estimate wherever shown.
    public static func estimatedTokens(_ text: String) -> Int { text.utf8.count / 4 }

    private static func isoDay(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day())
    }
}
