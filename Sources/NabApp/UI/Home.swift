import AppKit
import NabAI
import NabCore
import SwiftUI

/// The library home: the open session on top, earlier sessions by day below; the first-run view while the
/// library is empty.
struct HomePage: View {
    let model: LibraryModel
    @State private var filter = HomeFilter.all
    @State private var width: CGFloat = 1100
    @State private var clipboardID: String?

    private var center: CaptureCenter { model.center }

    var body: some View {
        if center.entries.isEmpty {
            FirstRunView(model: model)
        } else {
            let layout = HomeLayout.build(
                entries: center.entries, previews: model.assistant.previews(entries: center.entries),
                openSessionID: center.sessionID,
                filter: filter)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if let open = layout.open { openSection(open) }
                    ForEach(layout.days) { day in daySection(day) }
                    if layout.open == nil, layout.days.isEmpty { emptyFilter }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, Space.xl)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: {
                width = $0
            }
            .task(id: center.copiedIDs) { refreshClipboard() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                refreshClipboard()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            Text("Library").font(Typeface.largeTitle).tracking(Typeface.largeTitleTracking)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            let videos = center.entries.count
            let chats = model.assistant.conversations.count
            Text("\(videos) video\(videos == 1 ? "" : "s") · \(chats) chat\(chats == 1 ? "" : "s")")
                .font(Typeface.body).foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: 0)
            SegmentedPicker(
                [(HomeFilter.all, "All"), (.videos, "Videos"), (.chats, "Chats")], selection: $filter)
        }
    }

    private var emptyFilter: some View {
        Text(filter == .chats ? "No chats yet. Ask AI about a video to start one." : "Nothing here.")
            .font(Typeface.body).foregroundStyle(Palette.inkTertiary)
            .frame(maxWidth: .infinity, minHeight: 160)
    }

    // MARK: Sections

    private func openSection(_ session: HomeSession) -> some View {
        let ready = session.allEntryIDs.filter { center.entry($0)?.capture != nil }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Space.s) {
                SectionHeader(
                    title: "This session",
                    detail:
                        "\(session.allEntryIDs.count) video\(session.allEntryIDs.count == 1 ? "" : "s") · since \(clock(session.start))",
                    live: true)
                NabButton("End session", shortcut: "⌃⌥X", kind: .ghost) { center.closeSession(announce: true) }
                    .help("Close this session; the next video starts a new one")
                NabButton("Copy all", shortcut: "⌃⌥A") { center.copySession() }
                    .help("Copy the session's videos as one context pack")
                NabButton("Ask AI", shortcut: "⌃⌥S", kind: .primary) { model.ask(about: ready) }
                    .disabled(ready.isEmpty)
                    .help("Chat about the session and summarize it")
            }
            let columns = columnCount
            let cardWidth = (contentWidth - CGFloat(columns - 1) * Space.l) / CGFloat(columns)
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Space.l, alignment: .top), count: columns),
                alignment: .leading, spacing: Space.xl
            ) {
                ForEach(session.entryIDs, id: \.self) { id in
                    if let entry = center.entry(id) {
                        VideoCard(entry: entry, model: model, width: cardWidth, onClipboard: clipboardID == id)
                    }
                }
                ForEach(session.chats) { chat in
                    ChatCard(chat: chat, model: model, width: cardWidth)
                }
            }
        }
    }

    private func daySection(_ day: HomeDay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: day.title)
            WrapLayout(spacing: 28, lineSpacing: 20) {
                ForEach(day.sessions) { session in
                    VStack(alignment: .leading, spacing: 10) {
                        SessionLabel(session: session, model: model)
                        WrapLayout(spacing: Space.m, lineSpacing: Space.l) {
                            ForEach(session.entryIDs, id: \.self) { id in
                                if let entry = center.entry(id) {
                                    VideoCard(entry: entry, model: model, width: 196, small: true)
                                }
                            }
                            ForEach(session.chats) { chat in
                                ChatCard(chat: chat, model: model, width: 196, small: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Helpers

    private var contentWidth: CGFloat { max(width - 56, 600) }
    private var columnCount: Int { max(2, Int((contentWidth + Space.l) / (240 + Space.l))) }

    private func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// The entry whose context Nab's auto-copy put on the clipboard, while the clipboard still holds it.
    private func refreshClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !center.copiedIDs.isEmpty else {
            clipboardID = nil
            return
        }
        clipboardID =
            center.entries.first {
                center.copiedIDs.contains($0.id) && $0.capture.map { ContextPack.render([$0]) == text } == true
            }?.id
    }
}

// MARK: Cards

/// "author · language · ~13k tokens" for a ready entry; the phase otherwise.
@MainActor private func metaText(_ entry: Entry) -> String {
    guard entry.phase == .ready, let capture = entry.capture else { return entry.metaLine }
    var parts: [String] = []
    if let author = capture.author { parts.append(author) }
    if let transcript = capture.transcript {
        parts.append(transcript.languageName ?? transcript.languageCode)
        let k = max(1, Int((Double(TokenEstimate.tokens(entry)) / 1000).rounded()))
        parts.append("~\(k)k tokens")
    } else {
        parts.append("no transcript")
    }
    return parts.joined(separator: " · ")
}

/// Token estimates, kept per entry so a card does not walk a four-hour transcript on every render.
@MainActor
private enum TokenEstimate {
    private static var cache: [String: Int] = [:]

    static func tokens(_ entry: Entry) -> Int {
        let key = "\(entry.id)#\(entry.capture?.transcript?.segments.count ?? 0)"
        if let hit = cache[key] { return hit }
        let value = entry.capture?.transcript.map { $0.segments.reduce(0) { $0 + $1.text.utf8.count + 1 } / 4 } ?? 0
        cache[key] = value
        return value
    }
}

private struct VideoCard: View {
    let entry: Entry
    let model: LibraryModel
    let width: CGFloat
    var small = false
    var onClipboard = false
    @State private var hovering = false

    var body: some View {
        Button {
            model.go(.video(entry.id))
        } label: {
            VStack(alignment: .leading, spacing: small ? 8 : 10) {
                Thumbnail(
                    entry: entry, width: width, radius: small ? Radius.row : Radius.thumb, showsDuration: true,
                    badge: onClipboard ? .clipboard : nil
                )
                .overlay {
                    RoundedRectangle(cornerRadius: small ? Radius.row : Radius.thumb, style: .continuous)
                        .strokeBorder(Palette.accent, lineWidth: 2).opacity(hovering ? 1 : 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(small ? Typeface.rowTitle : Typeface.cardTitle)
                        .foregroundStyle(Palette.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if !small {
                        Text(metaText(entry))
                            .font(Typeface.meta)
                            .foregroundStyle(entry.phase == .failed ? Palette.error : Palette.inkTertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(width: width, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .entryContextMenu(entry, model: model)
        .accessibilityLabel(entry.title)
        .accessibilityHint(metaText(entry))
    }
}

private struct Sparkle: View {
    var size: CGFloat = 12
    var body: some View {
        Image(systemName: "sparkle").font(.system(size: size, weight: .bold)).foregroundStyle(Palette.accentInk)
            .accessibilityHidden(true)
    }
}

private struct ChatCard: View {
    let chat: ChatPreview
    let model: LibraryModel
    let width: CGFloat
    var small = false
    @State private var hovering = false

    var body: some View {
        Button {
            model.go(.session(chat.entryIDs))
        } label: {
            if small { compact } else { large }
        }
        .buttonStyle(PressableStyle(scale: 0.98))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .accessibilityLabel("Chat: \(chat.title)")
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Sparkle()
                Text(chat.model.map { "Chat · \(ModelNames.display($0))" } ?? "Chat").font(Typeface.label)
                    .foregroundStyle(Palette.accentInk)
            }
            Text(chat.title).font(Typeface.heading).foregroundStyle(Palette.ink).lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(chat.excerpt).font(Typeface.body).lineSpacing(3).foregroundStyle(Palette.inkSecondary)
                .lineLimit(4).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(chat.cites, id: \.self) { cite in
                    Text(cite.label).font(Typeface.chip).foregroundStyle(Palette.accentInk).lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Palette.accentWash, in: .rect(cornerRadius: Radius.chip, style: .continuous))
                }
                Spacer(minLength: 0)
                Text("\(chat.messageCount) message\(chat.messageCount == 1 ? "" : "s")")
                    .font(Typeface.meta).foregroundStyle(Palette.inkTertiary).lineLimit(1).fixedSize()
            }
        }
        .padding(Space.l)
        .frame(width: width, height: width * 9 / 16 + 74, alignment: .topLeading)
        .background(hovering ? Palette.selected : Palette.raised, in: card)
        .overlay(card.strokeBorder(hovering ? Palette.accentInk.opacity(0.7) : Palette.accentSoft))
        .contentShape(card)
    }

    private var compact: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Sparkle(size: 11)
                Text(chat.excerpt).font(Typeface.meta).lineSpacing(2).foregroundStyle(Palette.inkSecondary)
                    .lineLimit(4).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: width, height: width * 9 / 16, alignment: .topLeading)
            .background(hovering ? Palette.selected : Palette.raised, in: shape)
            .overlay(shape.strokeBorder(hovering ? Palette.accentInk.opacity(0.7) : Palette.accentSoft))
            Text(chat.title).font(Typeface.rowTitle).foregroundStyle(Palette.ink).lineLimit(2)
                .multilineTextAlignment(.leading).padding(.horizontal, 2)
        }
        .frame(width: width, alignment: .leading)
        .contentShape(.rect)
    }

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.card, style: .continuous) }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.row, style: .continuous) }
}

/// "14:02 · 2 videos · 1 chat"; click opens the session's chat page.
private struct SessionLabel: View {
    let session: HomeSession
    let model: LibraryModel
    @State private var hovering = false

    var body: some View {
        let parts = session.label.split(separator: "·", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        let ready = session.allEntryIDs.filter { model.center.entry($0)?.capture != nil }
        Button {
            model.go(.session(session.allEntryIDs))
        } label: {
            HStack(spacing: 0) {
                Text(parts.first ?? "").font(Typeface.label).foregroundStyle(Palette.inkSecondary)
                if parts.count > 1 {
                    Text(" · " + parts[1]).font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(hovering ? Palette.hover : .clear, in: .rect(cornerRadius: Radius.chip, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .padding(.horizontal, -6)
        .help("Open this session")
        .accessibilityLabel("Session \(session.label)")
        .contextMenu {
            Button("Open Chat") { model.go(.session(session.allEntryIDs)) }
            Button("Copy Context") { model.copyContext(of: ready) }.disabled(ready.isEmpty)
            Button("Summarize") { model.ask(about: ready) }.disabled(ready.isEmpty)
        }
    }
}

/// Lays its subviews out left to right and wraps at the proposed width.
struct WrapLayout: Layout {
    var spacing: CGFloat = 12
    var lineSpacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: .init(frame.size))
        }
    }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.init(width: maxWidth, height: nil))
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + lineHeight), frames)
    }
}
