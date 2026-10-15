import AppKit
import NabCore
import SwiftUI

/// The transcript beside a chat: one video's passages, with the cited moment lit and scrolled to the middle.
struct TranscriptDrawer: View {
    let entry: Entry
    /// The video's number in the chat, as citations count them.
    let number: Int?
    let model: LibraryModel
    /// The citation that opened the drawer, if one did.
    let focus: LibraryModel.Focus?
    let onClose: () -> Void
    @State private var query = ""
    /// Matches for `query`, rebuilt after typing pauses rather than on every render.
    @State private var search = TranscriptSearch(paragraphs: [], query: "")
    @State private var copied = false
    @FocusState private var finding: Bool

    var body: some View {
        let capture = entry.capture
        let paragraphs = capture.map { TranscriptCache.paragraphs(of: $0, id: entry.id, window: 8) } ?? []
        let lit = focus.flatMap { focus in paragraphs.lastIndex { $0.start <= focus.seconds + 0.5 } }
        VStack(spacing: 0) {
            header
            findField
            if paragraphs.isEmpty {
                Text(entry.phase == .fetching ? "Fetching transcript…" : "This video has no captions.")
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                passages(paragraphs, capture: capture, lit: lit)
            }
            footer(paragraphs)
        }
        .frame(width: Space.drawerWidth)
        .background(Palette.sunken)
        .overlay(alignment: .leading) { Rectangle().fill(Palette.line).frame(width: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Transcript")
        .task(id: SearchInput(query: query, segments: capture?.transcript?.segments.count)) {
            await rebuildSearch(paragraphs)
        }
    }

    private struct SearchInput: Equatable {
        let query: String
        let segments: Int?
    }

    /// Searches off the main thread after a short pause; typing again cancels this task and drops its answer.
    private func rebuildSearch(_ paragraphs: [Paragraph]) async {
        let query = query
        if !query.isEmpty, search.query != query.trimmingCharacters(in: .whitespacesAndNewlines) {
            try? await Task.sleep(for: .milliseconds(80))
        }
        guard !Task.isCancelled else { return }
        let found = await Task.detached(priority: .userInitiated) {
            TranscriptSearch(paragraphs: paragraphs, query: query)
        }.value
        guard !Task.isCancelled else { return }
        search = found
    }

    // MARK: Header and find

    private var header: some View {
        HStack(spacing: 10) {
            Thumbnail(entry: entry, width: 48, radius: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text((number.map { "\($0) · " } ?? "") + entry.title)
                    .font(Typeface.rowTitle)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text("Transcript" + (language.map { " · \($0)" } ?? ""))
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(Typeface.iconSmall)
                    .foregroundStyle(Palette.inkSecondary)
                    .frame(width: 26, height: 26)
                    .background(Palette.control, in: .rect(cornerRadius: 8, style: .continuous))
                    .contentShape(.rect)
            }
            .buttonStyle(PressableStyle())
            .help("Close transcript (Esc)")
            .accessibilityLabel("Close transcript")
        }
        .padding(.leading, Space.l)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var language: String? {
        entry.capture?.transcript.map { $0.languageName ?? $0.languageCode }
    }

    private var findField: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "magnifyingglass").font(Typeface.iconSmall).foregroundStyle(Palette.inkTertiary)
            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .font(Typeface.meta)
                .foregroundStyle(Palette.ink)
                .focused($finding)
                .accessibilityLabel("Find in transcript")
            if search.isActive {
                Text(search.matches.isEmpty ? "No matches" : "\(search.matches.count)")
                    .font(Typeface.meta)
                    .foregroundStyle(Palette.inkTertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Palette.raised, in: .rect(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(finding ? Palette.accent : Palette.line, lineWidth: finding ? 1.5 : 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, Space.s)
    }

    // MARK: Passages

    private func passages(_ paragraphs: [Paragraph], capture: Capture?, lit: Int?)
        -> some View
    {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(paragraphs.enumerated()), id: \.element.id) { index, paragraph in
                        PassageRow(
                            paragraph: paragraph, url: capture?.url(at: paragraph.start),
                            matches: search.matches(inParagraph: index), lit: index == lit
                        )
                        .id(paragraph.start)
                    }
                }
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xs)
            }
            .task(id: focus?.token) {
                guard let lit else { return }
                try? await Task.sleep(for: .milliseconds(80))
                withAnimation(Motion.settle) { proxy.scrollTo(paragraphs[lit].start, anchor: .center) }
            }
            .onChange(of: search.query) {
                guard let first = search.matches.first else { return }
                withAnimation(Motion.settle) { proxy.scrollTo(paragraphs[first.paragraph].start, anchor: .center) }
            }
        }
    }

    private func footer(_ paragraphs: [Paragraph]) -> some View {
        HStack {
            Button {
                model.go(.video(entry.id))
            } label: {
                DrawerLinkLabel(title: "Open full transcript ›", rest: Palette.inkSecondary)
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .help("Open the video page")
            Spacer()
            Button {
                Pasteboard.copy(TranscriptText.plain(paragraphs))
                withAnimation(Motion.snap) { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    withAnimation(Motion.settle) { copied = false }
                }
            } label: {
                DrawerLinkLabel(title: copied ? "Copied" : "Copy", rest: Palette.inkTertiary)
            }
            .buttonStyle(PressableStyle(scale: 0.97))
            .disabled(paragraphs.isEmpty)
            .help("Copy the transcript")
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .overlay(alignment: .top) { Rectangle().fill(Palette.line).frame(height: 1) }
    }
}

/// Quiet text that turns lime on hover.
private struct DrawerLinkLabel: View {
    let title: String
    let rest: Color
    @State private var hovering = false

    var body: some View {
        Text(title).font(Typeface.meta)
            .foregroundStyle(hovering ? Palette.accentInk : rest)
            .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }
}

/// One passage: its timecode (opens the video there) and text, washed when it is the cited moment.
private struct PassageRow: View {
    let paragraph: Paragraph
    let url: URL?
    let matches: [(index: Int, match: TranscriptMatch)]
    let lit: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                if let url { NSWorkspace.shared.open(url) }
            } label: {
                Text(Timecode.string(paragraph.start))
                    .font(lit ? Typeface.chip : Typeface.mono)
                    .foregroundStyle(lit || hovering ? Palette.accentInk : Palette.inkTertiary)
                    .frame(width: 40, alignment: .leading)
                    .padding(.top, 2)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .onHover { over in withAnimation(Motion.snap) { hovering = over } }
            .help("Open at \(Timecode.string(paragraph.start))")
            Text(TranscriptText.marked(paragraph.text, matches: matches, current: nil))
                .font(Typeface.body)
                .lineSpacing(4)
                .foregroundStyle(lit ? Palette.ink : Palette.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Space.s)
        .padding(.vertical, 7)
        .background(lit ? Palette.accentWash : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .animation(Motion.snap, value: lit)
    }
}
