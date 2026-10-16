import AppKit
import NabCore
import SwiftUI

/// One video: cover, facts and chapters on the left, the transcript with find and a timeline on the right.
struct VideoPage: View {
    let entryID: String
    let model: LibraryModel

    var body: some View {
        if let entry = model.center.entry(entryID) {
            VideoContent(entry: entry, model: model)
        } else {
            Text("This video is no longer in the library.")
                .font(Typeface.meta)
                .foregroundStyle(Palette.inkTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ScrollRequest: Equatable {
    let target: TimeInterval
    let token = UUID()
}

private struct VideoContent: View {
    let entry: Entry
    let model: LibraryModel
    @State private var query = ""
    @State private var search = TranscriptSearch(paragraphs: [], query: "")
    @State private var current: Int?
    /// The moment the timeline and the chapter list point at: the current hit, a citation, or a chapter just picked.
    @State private var position: TimeInterval?
    /// The passage a citation pointed at, lit for a moment.
    @State private var highlighted: TimeInterval?
    @State private var scroll: ScrollRequest?
    @State private var tokens: Int?
    @State private var copiedContext = false
    @State private var copiedTranscript = false
    @FocusState private var finding: Bool
    @State private var hoveredChapter: Int?
    @State private var timelineWidth: CGFloat = 0

    private var capture: Capture? { entry.capture }
    private var paragraphs: [Paragraph] { capture.map { TranscriptCache.paragraphs(of: $0, id: entry.id) } ?? [] }
    private var chapters: [Chapter] { capture?.chapters ?? [] }

    var body: some View {
        HStack(spacing: 0) {
            aside.frame(width: 344)
            Rectangle().fill(Palette.line).frame(width: 1)
            transcriptSection
        }
        .task(id: entry.id) { await loadTokens() }
        // A window that opens focuses its first text field, which would light the find field whenever a video is
        // opened from outside the library. Find takes focus only when asked: ⌘F or a click.
        .task(id: entry.id) {
            try? await Task.sleep(for: .milliseconds(120))
            finding = false
        }
        .onChange(of: capture?.transcript?.segments.count) { rebuildSearch() }
        // `initial` because a page opened by a transcript hit or a citation is created with the focus already set.
        .onChange(of: model.focus, initial: true) { _, focus in
            guard let focus, focus.entryID == entry.id,
                let target = paragraphs.last(where: { $0.start <= focus.seconds + 0.5 })?.start
            else { return }
            position = focus.seconds
            withAnimation(Motion.snap) { highlighted = target }
            Task {
                // The list is only just on screen when the page opens on a hit; let it lay out before scrolling.
                try? await Task.sleep(for: .milliseconds(80))
                scroll = ScrollRequest(target: target)
                try? await Task.sleep(for: .seconds(2.2))
                if highlighted == target { withAnimation(Motion.highlightFade) { highlighted = nil } }
            }
        }
        .background {
            Button("Find in transcript") { finding = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func loadTokens() async {
        guard let capture else {
            tokens = nil
            return
        }
        tokens = await Task.detached { ContextPack.estimatedTokens(ContextPack.render([capture])) }.value
    }

    // MARK: Left column

    private var aside: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VideoCover(entry: entry, onClipboard: model.center.copiedIDs.contains(entry.id))
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.title)
                        .font(Typeface.videoTitle)
                        .foregroundStyle(Palette.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    status
                }
                chips
                actions
                if !chapters.isEmpty { chapterList }
            }
            .padding(20)
        }
        .scrollIndicators(.never)
    }

    @ViewBuilder private var status: some View {
        switch entry.phase {
        case .fetching:
            HStack(spacing: Space.s) {
                PhaseMark(phase: .fetching)
                Text("Fetching transcript…")
            }
            .font(Typeface.meta)
            .foregroundStyle(Palette.inkSecondary)
        case .failed:
            Text("Could not be read").font(Typeface.meta).foregroundStyle(Palette.error)
        case .ready:
            let fetched = "fetched " + entry.addedAt.formatted(date: .omitted, time: .shortened)
            Text([capture?.author, fetched].compactMap { $0 }.joined(separator: " · "))
                .font(Typeface.meta)
                .foregroundStyle(Palette.inkTertiary)
        }
    }

    @ViewBuilder private var chips: some View {
        if let transcript = capture?.transcript {
            FlowRow(spacing: 6) {
                InfoChip(text: transcript.languageName ?? transcript.languageCode)
                if transcript.isGenerated { InfoChip(text: "auto-generated") }
                if let tokens { InfoChip(text: "~\(tokens.formatted()) tokens") }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: Space.s) {
            switch entry.phase {
            case .ready:
                NabButton(
                    "Ask AI about this video", kind: .primary, size: .large, fullWidth: true, action: model.summarize)
                Grid(horizontalSpacing: Space.s, verticalSpacing: Space.s) {
                    GridRow {
                        NabButton(copiedContext ? "Copied" : "Copy context", fullWidth: true) {
                            guard let capture else { return }
                            Pasteboard.copy(ContextPack.render([capture]))
                            flash($copiedContext)
                        }
                        NabButton("Open on YouTube", fullWidth: true) { NSWorkspace.shared.open(entry.url) }
                    }
                    GridRow {
                        NabButton("Export…", fullWidth: true, action: model.export)
                            .help("Save the video's context as a Markdown file")
                        NabButton("Fetch again", fullWidth: true) { model.center.retry(entry.id) }
                    }
                }
            case .failed:
                NabButton("Try again", kind: .primary, size: .large, fullWidth: true) { model.center.retry(entry.id) }
            case .fetching:
                EmptyView()
            }
        }
    }

    private func flash(_ flag: Binding<Bool>) {
        withAnimation(Motion.snap) { flag.wrappedValue = true }
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            withAnimation(Motion.settle) { flag.wrappedValue = false }
        }
    }

    private var chapterList: some View {
        let active = position.flatMap { TranscriptSearch.chapterIndex(at: $0, in: chapters) }
        return VStack(spacing: 2) {
            HStack {
                Text("Chapters")
                Spacer()
                Text("\(chapters.count)").fontWeight(.regular)
            }
            .font(Typeface.label)
            .foregroundStyle(Palette.inkTertiary)
            .padding(.horizontal, Space.s)
            .padding(.bottom, 6)
            ForEach(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                ChapterRow(
                    chapter: chapter, hits: search.count(inChapter: index), current: index == active
                ) {
                    if NSEvent.modifierFlags.contains(.command), let capture {
                        NSWorkspace.shared.open(capture.url(at: chapter.start))
                    } else if let target = paragraphs.last(where: { $0.start <= chapter.start + 0.5 })?.start {
                        position = chapter.start
                        scroll = ScrollRequest(target: target)
                    }
                }
            }
        }
        .padding(.top, 4)
    }

    // MARK: Right column

    private var transcriptSection: some View {
        VStack(spacing: 0) {
            header
            if capture?.transcript != nil {
                timeline
                transcriptBody
            } else {
                emptyBody
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Transcript").font(Typeface.title).foregroundStyle(Palette.ink)
            if let transcript = capture?.transcript {
                Text(transcript.languageName ?? transcript.languageCode)
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkSecondary)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Palette.raised, in: .capsule)
                    .overlay(Capsule().strokeBorder(Palette.line))
            }
            Spacer(minLength: Space.s)
            if capture?.transcript != nil {
                findField
                NabButton(copiedTranscript ? "Copied" : "Copy") {
                    Pasteboard.copy(TranscriptText.plain(paragraphs))
                    flash($copiedTranscript)
                }
                .help("Copy the transcript")
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 20)
        .frame(height: 60)
    }

    private var findField: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").font(Typeface.iconSmall).foregroundStyle(Palette.inkSecondary)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .font(Typeface.body)
                .foregroundStyle(Palette.ink)
                .focused($finding)
                .onSubmit { step(forward: true) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    step(forward: false)
                    return .handled
                }
                .onKeyPress(.escape, phases: .down) { _ in
                    guard !query.isEmpty else { return .ignored }
                    query = ""
                    return .handled
                }
                .accessibilityLabel("Find in transcript")
            if search.isActive {
                Text(counter).font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1).fixedSize()
                HStack(spacing: 0) {
                    FieldIconButton(symbol: "chevron.up", help: "Previous match (⇧Return)") { step(forward: false) }
                    FieldIconButton(symbol: "chevron.down", help: "Next match (Return)") { step(forward: true) }
                }
                .disabled(search.matches.isEmpty)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(width: 250, height: 30)
        .background(Palette.raised, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(finding ? Palette.accent : Palette.line, lineWidth: finding ? 1.5 : 1)
        )
        .animation(Motion.snap, value: finding)
        .onChange(of: query) {
            rebuildSearch()
            current = search.index(after: nil)
            if let current { reveal(current) } else { position = nil }
        }
    }

    private var counter: String {
        guard let current, !search.matches.isEmpty else { return "No matches" }
        return "\(current + 1) of \(search.matches.count)"
    }

    private func rebuildSearch() {
        search = TranscriptSearch(paragraphs: paragraphs, chapters: chapters, query: query)
        if let current, current >= search.matches.count { self.current = nil }
    }

    private func step(forward: Bool) {
        guard search.isActive else { return }
        current = forward ? search.index(after: current) : search.index(before: current)
        if let current { reveal(current) }
    }

    private func reveal(_ index: Int) {
        let match = search.matches[index]
        position = match.time
        scroll = ScrollRequest(target: paragraphs[match.paragraph].start)
    }

    // MARK: Timeline

    private var total: TimeInterval {
        max(capture?.duration ?? 0, paragraphs.last?.start ?? 0, chapters.last?.start ?? 0, 1)
    }

    private var timeline: some View {
        let active = position.flatMap { TranscriptSearch.chapterIndex(at: $0, in: chapters) }
        return VStack(alignment: .leading, spacing: Space.s) {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 2) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                            Capsule()
                                .fill(
                                    segment.chapter.map { $0 == active || $0 == hoveredChapter } == true
                                        ? Palette.accent
                                        : segment.chapter.map { $0 <= (active ?? -1) } ?? (position != nil)
                                            ? Palette.inkSecondary : Palette.lineStrong
                                )
                                .frame(height: 3)
                                .frame(maxWidth: .infinity)
                                .layoutPriority(segment.length)
                                .frame(width: max(2, segment.length / total * proxy.size.width - 2))
                        }
                    }
                    .offset(y: 8)
                    ForEach(Array(search.matches.enumerated()), id: \.offset) { index, match in
                        Capsule()
                            .fill(index == current ? Palette.accent : Palette.accentSoft)
                            .frame(width: 2, height: 13)
                            .offset(x: min(match.time / total, 1) * (proxy.size.width - 2), y: 3)
                    }
                }
            }
            .frame(height: 18)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoveredChapter = chapter(atFraction: point.x, in: timelineWidth)
                case .ended: hoveredChapter = nil
                }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                timelineWidth = $0
            }
            HStack {
                Text(chapterLine).font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1)
                Spacer(minLength: Space.m)
                Text(timeLine).font(Typeface.mono).foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.leading, 32)
        .padding(.trailing, 20)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(Palette.line).frame(height: 1) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline: \(chapterLine), \(timeLine)")
    }

    /// Bars of the timeline: one per chapter, or a single one.
    private var segments: [(chapter: Int?, length: TimeInterval)] {
        guard !chapters.isEmpty else { return [(nil, total)] }
        return chapters.indices.map { index in
            let end = index + 1 < chapters.count ? chapters[index + 1].start : total
            return (index, max(end - chapters[index].start, 1))
        }
    }

    private func chapter(atFraction x: CGFloat, in width: CGFloat) -> Int? {
        guard !chapters.isEmpty, width > 0 else { return nil }
        let time = TimeInterval(x / width) * total
        return TranscriptSearch.chapterIndex(at: time, in: chapters)
    }

    private var chapterLine: String {
        guard !chapters.isEmpty else { return "No chapters" }
        guard let position, let index = TranscriptSearch.chapterIndex(at: position, in: chapters) else {
            return "\(chapters.count) chapters"
        }
        return "Chapter \(index + 1) of \(chapters.count) · \(chapters[index].title)"
    }

    private var timeLine: String {
        let end = Timecode.string(capture?.duration ?? total)
        return position.map { "\(Timecode.string($0)) / \(end)" } ?? end
    }

    // MARK: Transcript

    private var transcriptBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                        VStack(alignment: .leading, spacing: 14) {
                            if let chapter = paragraph.chapter {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(Timecode.string(paragraph.start))
                                        .font(Typeface.mono)
                                        .foregroundStyle(Palette.inkTertiary)
                                        .frame(width: 44, alignment: .leading)
                                    Text(chapter).font(Typeface.heading).foregroundStyle(Palette.ink)
                                }
                                .padding(.top, Space.m)
                            }
                            ParagraphRow(
                                paragraph: paragraph, url: capture?.url(at: paragraph.start),
                                matches: search.matches(inParagraph: index), current: current,
                                lit: highlighted == paragraph.start)
                        }
                        .id(paragraph.start)
                    }
                }
                .frame(maxWidth: 700, alignment: .leading)
                .padding(.horizontal, 32)
                .padding(.vertical, Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: scroll) { _, request in
                guard let request else { return }
                withAnimation(Motion.settle) { proxy.scrollTo(request.target, anchor: .center) }
            }
        }
    }

    @ViewBuilder private var emptyBody: some View {
        VStack(spacing: Space.m) {
            switch entry.phase {
            case .fetching:
                ProgressView().controlSize(.small)
                Text("Fetching transcript…").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
            case .failed:
                Text(entry.failure ?? "Something went wrong.")
                    .font(Typeface.body)
                    .foregroundStyle(Palette.error)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                NabButton("Try Again", kind: .primary) { model.center.retry(entry.id) }
            case .ready:
                Text("This video has no captions.").font(Typeface.heading).foregroundStyle(Palette.ink)
                Text("YouTube has none to give. Its details are still in the context pack.")
                    .font(Typeface.body)
                    .foregroundStyle(Palette.inkSecondary)
            }
        }
        .padding(Space.xxl)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Pieces

/// A timecode and its passage. Find hits are washed and the current one filled; a cited passage is lit.
private struct ParagraphRow: View {
    let paragraph: Paragraph
    let url: URL?
    let matches: [(index: Int, match: TranscriptMatch)]
    let current: Int?
    let lit: Bool
    @State private var hovering = false

    private var hasCurrent: Bool { matches.contains { $0.index == current } }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                Text(Timecode.string(paragraph.start))
                    .font(Typeface.chip)
                    .foregroundStyle(lit || hasCurrent || hovering ? Palette.accentInk : Palette.inkTertiary)
                    .frame(width: 44, alignment: .leading)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { over in withAnimation(Motion.snap) { hovering = over } }
            .help("Open at \(Timecode.string(paragraph.start))")
            Text(TranscriptText.marked(paragraph.text, matches: matches, current: current))
                .font(Typeface.reading)
                .lineSpacing(Typeface.readingLineSpacing)
                .foregroundStyle(Palette.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(Palette.accentWash)
                .padding(.vertical, -6)
                .padding(.horizontal, -8)
                .opacity(lit ? 1 : 0)
        }
    }
}

private struct ChapterRow: View {
    let chapter: Chapter
    let hits: Int
    let current: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(Timecode.string(chapter.start))
                    .font(Typeface.chip)
                    .foregroundStyle(current || hovering ? Palette.accentInk : Palette.inkTertiary)
                    .frame(width: 48, alignment: .leading)
                Text(chapter.title)
                    .font(current ? Typeface.rowTitle : Typeface.body)
                    .foregroundStyle(current ? Palette.ink : Palette.inkSecondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if hits > 0 {
                    Text("\(hits)")
                        .font(Typeface.chip)
                        .foregroundStyle(Palette.accentInk)
                        .padding(.horizontal, 5)
                        .background(Palette.accentWash, in: .rect(cornerRadius: 5, style: .continuous))
                }
            }
            .padding(.horizontal, Space.s)
            .frame(height: 28)
            .background(
                current ? Palette.selected : (hovering ? Palette.hover : .clear),
                in: .rect(cornerRadius: Radius.row - 2, style: .continuous)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .help("Show in the transcript (⌘-click opens the video there)")
        .accessibilityLabel("\(chapter.title), \(Timecode.string(chapter.start))")
    }
}

private struct InfoChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Typeface.meta)
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Palette.raised, in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.line))
    }
}

/// Chips that wrap onto further lines.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}

/// The video's cover at column width; a click opens the video. Takes the largest cover the source has.
private struct VideoCover: View {
    let entry: Entry
    let onClipboard: Bool
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(entry.url)
        } label: {
            Palette.well
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    if let image = CoverCache.cached(entry) ?? image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                    }
                }
                .overlay {
                    Image(systemName: "play.fill")
                        .font(Typeface.iconMark)
                        .foregroundStyle(Palette.onScrim)
                        .frame(width: 48, height: 48)
                        .background(Palette.scrimStrong, in: .circle)
                        .opacity(hovering ? 1 : 0)
                        .scaleEffect(hovering ? 1 : 0.85)
                }
                .overlay(alignment: .topLeading) { if onClipboard { ClipboardPill().padding(8) } }
                .overlay(alignment: .bottomTrailing) {
                    if !entry.durationText.isEmpty {
                        Text(entry.durationText)
                            .font(Typeface.mono)
                            .foregroundStyle(Palette.onScrim)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Color.black.opacity(0.62), in: .rect(cornerRadius: Radius.chip, style: .continuous)
                            )
                            .padding(8)
                    }
                }
                .clipShape(.rect(cornerRadius: Radius.thumb, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.thumb, style: .continuous).strokeBorder(Palette.line))
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.99))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .help("Open the video")
        .accessibilityLabel("Open the video")
        .task(id: entry.id) {
            guard CoverCache.cached(entry) == nil else { return }
            let loaded = await CoverCache.image(for: entry)
            withAnimation(Motion.settle) { image = loaded }
        }
    }
}

@MainActor
enum CoverCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ entry: Entry) -> NSImage? { cache.object(forKey: entry.id as NSString) }

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
