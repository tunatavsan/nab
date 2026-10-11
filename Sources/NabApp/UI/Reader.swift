import AppKit
import NabCore
import SwiftUI

/// One capture: cover, title, facts in a quiet line, chapters,
/// then the transcript in timecoded passages that open the video at that moment.
struct ReaderView: View {
    let entry: Entry
    let model: LibraryModel
    /// The passage a chat citation pointed at, lit for a moment.
    @State private var highlighted: TimeInterval?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Space.xl) {
                    header
                    if let capture = entry.capture {
                        if !capture.chapters.isEmpty { chapters(capture) }
                        transcript(capture)
                    } else if entry.phase == .failed {
                        failure
                    }
                }
                .frame(maxWidth: Space.readingWidth, alignment: .leading)
                .padding(.horizontal, Space.xxl)
                .padding(.top, Space.xl)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onChange(of: model.focus) { _, focus in
                guard let focus, focus.entryID == entry.id, let capture = entry.capture,
                    let target = capture.transcript?.paragraphs(chapters: capture.chapters)
                        .last(where: { $0.start <= focus.seconds + 0.5 })?.start
                else { return }
                withAnimation(Motion.settle) { proxy.scrollTo(target, anchor: .center) }
                withAnimation(Motion.snap) { highlighted = target }
                Task {
                    try? await Task.sleep(for: .seconds(2.2))
                    if highlighted == target { withAnimation(.easeOut(duration: 0.8)) { highlighted = nil } }
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Cover(entry: entry)
                .padding(.bottom, Space.s)
            SectionLabel(
                [entry.capture?.source.rawValue ?? "Link", entry.capture?.author].compactMap { $0 }.joined(
                    separator: " · "))
            Text(entry.title)
                .font(Typeface.display)
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            facts
            if let capture = entry.capture {
                HStack(spacing: Space.s) {
                    ConfirmingButton(
                        title: "Copy Context", confirmation: "Copied", systemImage: "doc.on.doc", prominent: true
                    ) {
                        Pasteboard.copy(ContextPack.render([capture]))
                    }
                    Button(
                        capture.aiSummary == nil ? "Summarize" : "Chat",
                        systemImage: capture.aiSummary == nil ? "sparkles" : "bubble.left.and.text.bubble.right",
                        action: model.summarize
                    )
                    .buttonStyle(.glass)
                    .font(Typeface.rowTitle)
                    Button("Open", systemImage: "arrow.up.right") { NSWorkspace.shared.open(capture.url) }
                        .buttonStyle(.glass)
                        .font(Typeface.rowTitle)
                    Button("Export", systemImage: "square.and.arrow.down", action: model.export)
                        .buttonStyle(.glass)
                        .font(Typeface.rowTitle)
                }
                .padding(.top, Space.xs)
            }
        }
    }

    private var facts: some View {
        HStack(spacing: Space.s) {
            switch entry.phase {
            case .fetching:
                PhaseMark(phase: .fetching)
                Text("Fetching transcript…")
            case .failed:
                Text("Could not be read")
            case .ready:
                Text(factLine)
            }
        }
        .font(Typeface.meta)
        .foregroundStyle(Palette.inkSecondary)
    }

    private var factLine: String {
        guard let c = entry.capture else { return "" }
        var parts: [String] = []
        if let d = c.duration { parts.append(Timecode.string(d)) }
        if let v = c.viewCount { parts.append("\(v.formatted(.number.notation(.compactName))) views") }
        if let t = c.transcript {
            parts.append("\(t.wordCount.formatted()) words")
            parts.append((t.languageName ?? t.languageCode) + (t.isGenerated ? ", auto" : ""))
        } else {
            parts.append("No transcript on this video")
        }
        return parts.joined(separator: "  ·  ")
    }

    private func chapters(_ capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            SectionLabel("Chapters")
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(capture.chapters, id: \.start) { chapter in
                    TimecodeLink(seconds: chapter.start, url: capture.url(at: chapter.start)) {
                        Text(chapter.title).font(Typeface.body).foregroundStyle(Palette.ink)
                    }
                }
            }
        }
    }

    private func transcript(_ capture: Capture) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            SectionLabel("Transcript")
            if let transcript = capture.transcript {
                LazyVStack(alignment: .leading, spacing: Space.l) {
                    ForEach(transcript.paragraphs(chapters: capture.chapters)) { paragraph in
                        if let chapter = paragraph.chapter {
                            Text(chapter)
                                .font(Typeface.rowTitle)
                                .foregroundStyle(Palette.ink)
                                .padding(.top, Space.m)
                        }
                        TimecodeLink(seconds: paragraph.start, url: capture.url(at: paragraph.start)) {
                            Text(paragraph.text)
                                .font(Typeface.reading)
                                .lineSpacing(Typeface.readingLineSpacing)
                                .foregroundStyle(Palette.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .background {
                            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                                .fill(Palette.accentWash)
                                .padding(-Space.s)
                                .opacity(highlighted == paragraph.start ? 1 : 0)
                        }
                        .id(paragraph.start)
                    }
                }
            } else {
                Text("YouTube has no captions for this video. Its details are still in the context pack.")
                    .font(Typeface.reading)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
    }

    private var failure: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(entry.failure ?? "Something went wrong.")
                .font(Typeface.reading)
                .foregroundStyle(Palette.accent)
            Button("Try Again", systemImage: "arrow.clockwise") { model.center.retry(entry.id) }
                .buttonStyle(.glass)
        }
    }
}

/// A timecode in the gutter that opens the source at that moment; the content sits beside it.
private struct TimecodeLink<Content: View>: View {
    let seconds: TimeInterval
    let url: URL
    @ViewBuilder let content: Content
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            Button(Timecode.string(seconds)) { NSWorkspace.shared.open(url) }
                .buttonStyle(PressableStyle())
                .font(Typeface.mono)
                .foregroundStyle(hovering ? Palette.accent : Palette.inkTertiary)
                .frame(width: 56, alignment: .trailing)
                .onHover { over in withAnimation(Motion.snap) { hovering = over } }
                .help("Open at \(Timecode.string(seconds))")
            content
        }
    }
}

/// Several captures selected: what the pack will contain and how big it is.
struct PackView: View {
    let entries: [Entry]
    let model: LibraryModel

    var body: some View {
        let captures = entries.compactMap(\.capture)
        let text = ContextPack.render(captures)
        let total = captures.compactMap(\.duration).reduce(0, +)
        VStack(alignment: .leading, spacing: Space.xl) {
            VStack(alignment: .leading, spacing: Space.m) {
                SectionLabel("Context pack")
                Text("\(captures.count) videos")
                    .font(Typeface.display)
                    .foregroundStyle(Palette.ink)
                    .contentTransition(.numericText())
                Text("\(Timecode.string(total)) of video  ·  ≈ \(ContextPack.estimatedTokens(text).formatted()) tokens")
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkSecondary)
                HStack(spacing: Space.s) {
                    ConfirmingButton(
                        title: "Copy Context", confirmation: "Copied", systemImage: "doc.on.doc", prominent: true
                    ) {
                        Pasteboard.copy(text)
                    }
                    Button("Summarize All", systemImage: "sparkles", action: model.summarize)
                        .buttonStyle(.glass)
                        .font(Typeface.rowTitle)
                        .disabled(captures.isEmpty)
                    Button("Export", systemImage: "square.and.arrow.down", action: model.export)
                        .buttonStyle(.glass)
                        .font(Typeface.rowTitle)
                }
                .padding(.top, Space.xs)
            }
            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                        Text("\(index + 1)")
                            .font(Typeface.mono)
                            .foregroundStyle(Palette.inkTertiary)
                            .frame(width: 24, alignment: .trailing)
                        Text(entry.title).font(Typeface.rowTitle).foregroundStyle(Palette.ink)
                        Spacer()
                        Text(entry.capture?.duration.map(Timecode.string) ?? entry.metaLine)
                            .font(Typeface.mono)
                            .foregroundStyle(Palette.inkTertiary)
                    }
                    .transition(.rise)
                }
            }
            .animation(Motion.settle, value: entries.map(\.id))
            Spacer()
        }
        .frame(maxWidth: Space.readingWidth, alignment: .leading)
        .padding(Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The video's cover at reading width; a click opens the video. Takes the largest cover YouTube has.
private struct Cover: View {
    let entry: Entry
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(entry.url)
        } label: {
            Palette.well
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    }
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .glassEffect(.regular, in: .circle)
                        .opacity(hovering ? 1 : 0)
                        .scaleEffect(hovering ? 1 : 0.85)
                }
                .clipShape(.rect(cornerRadius: Radius.cell, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.cell, style: .continuous).strokeBorder(Palette.hairline))
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .help("Open the video")
        .task(id: entry.id) {
            let loaded = await CoverCache.image(for: entry)
            withAnimation(Motion.settle) { image = loaded }
        }
    }
}

@MainActor
enum CoverCache {
    private static let cache = NSCache<NSString, NSImage>()

    /// maxresdefault is missing on some videos (YouTube answers 404 with a tiny placeholder), so
    /// each candidate is checked for status and size before falling back.
    static func image(for entry: Entry) async -> NSImage? {
        if let hit = cache.object(forKey: entry.id as NSString) { return hit }
        for url in entry.coverURLs {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                (response as? HTTPURLResponse)?.statusCode == 200,
                let image = NSImage(data: data), image.size.width > 200
            else { continue }
            cache.setObject(image, forKey: entry.id as NSString)
            return image
        }
        return nil
    }
}

extension Entry {
    /// Largest first.
    var coverURLs: [URL] {
        guard id.hasPrefix("youtube:") else { return [capture?.thumbnailURL].compactMap { $0 } }
        let video = id.dropFirst("youtube:".count)
        return ["maxresdefault", "hqdefault"].compactMap { URL(string: "https://i.ytimg.com/vi/\(video)/\($0).jpg") }
    }
}
