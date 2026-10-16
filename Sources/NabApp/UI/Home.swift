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
    @AppStorage("onboarding.version") private var onboardingSeen = 0

    private var center: CaptureCenter { model.center }

    var body: some View {
        if center.entries.isEmpty {
            if Onboarding.opensAutomatically(libraryIsEmpty: true, seenVersion: onboardingSeen) {
                OnboardingView(model: model)
            } else {
                FirstRunView(model: model)
            }
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
        let shortcuts = ShortcutStore.shared
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Space.s) {
                SectionHeader(
                    title: "This session",
                    detail:
                        "\(session.allEntryIDs.count) video\(session.allEntryIDs.count == 1 ? "" : "s") · since \(clock(session.start))",
                    live: true)
                NabButton("End session", combo: shortcuts.combo(for: .newSession), kind: .ghost) {
                    center.closeSession(announce: true)
                }
                .help("Close this session; the next video starts a new one")
                NabButton("Copy all", combo: shortcuts.combo(for: .copySession)) { center.copySession() }
                    .help("Copy the session's videos as one context pack")
                NabButton("Ask AI", combo: shortcuts.combo(for: .summarize), kind: .primary) { model.ask(about: ready) }
                    .disabled(ready.isEmpty)
                    .help("Chat about the session and summarize it")
            }
            grid([cells(of: session)], sessions: nil, columns: Self.openColumns, large: true)
        }
    }

    private func daySection(_ day: HomeDay) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: day.title)
            grid(day.sessions.map(cells(of:)), sessions: day.sessions, columns: Self.dayColumns, large: false)
        }
    }

    // MARK: Grid

    /// A card on the grid: a video or a chat.
    private enum Cell: Identifiable {
        case video(Entry)
        case chat(ChatPreview)

        var id: String {
            switch self {
            case .video(let entry): "v-" + entry.id
            case .chat(let chat): "c-" + chat.id
            }
        }
    }

    private func cells(of session: HomeSession) -> [Cell] {
        session.entryIDs.compactMap { center.entry($0).map(Cell.video) } + session.chats.map(Cell.chat)
    }

    /// One aligned grid of equal columns. Each session's cells follow the previous session's, wrapping at the
    /// right edge; with `sessions`, a band above every row labels each session's run of cells.
    private func grid(_ groups: [[Cell]], sessions: [HomeSession]?, columns: Int, large: Bool) -> some View {
        let flat = groups.flatMap { $0 }
        let runs = HomeGrid.runs(itemCounts: groups.map(\.count), columns: columns)
        let cardWidth = (contentWidth - CGFloat(columns - 1) * Space.l) / CGFloat(columns)
        let rows = stride(from: 0, to: flat.count, by: columns).map { Array(flat[$0..<min($0 + columns, flat.count)]) }
        return VStack(alignment: .leading, spacing: Space.xl) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 8) {
                    if let sessions {
                        runBand(runs.filter { $0.row == index }, sessions: sessions, cardWidth: cardWidth)
                    }
                    HStack(alignment: .top, spacing: Space.l) {
                        ForEach(row) { cell in
                            card(cell, width: cardWidth, large: large)
                                .frame(width: cardWidth, alignment: .topLeading)
                        }
                    }
                }
            }
        }
    }

    /// The label band of one grid row: a rule under each run's cells, the session label on the first run.
    private func runBand(_ runs: [HomeGrid.Run], sessions: [HomeSession], cardWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(runs, id: \.column) { run in
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if run.continues {
                            Color.clear
                        } else {
                            SessionLabel(session: sessions[run.session], model: model)
                        }
                    }
                    .frame(height: 20, alignment: .leading)
                    Rectangle().fill(Palette.line).frame(height: 1)
                }
                .frame(width: CGFloat(run.length) * cardWidth + CGFloat(run.length - 1) * Space.l)
                .offset(x: CGFloat(run.column) * (cardWidth + Space.l))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 25, maxHeight: 25, alignment: .topLeading)
    }

    @ViewBuilder
    private func card(_ cell: Cell, width: CGFloat, large: Bool) -> some View {
        switch cell {
        case .video(let entry):
            VideoCard(entry: entry, model: model, width: width, small: !large, onClipboard: clipboardID == entry.id)
        case .chat(let chat):
            ChatCard(chat: chat, model: model, width: width, small: !large)
        }
    }

    // MARK: Helpers

    private var contentWidth: CGFloat { max(width - 56, 600) }
    /// Columns are fixed so cards line up the same way at every width; only their width follows the window.
    private static let dayColumns = 5
    private static let openColumns = 4

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
            .lineLimit(1)
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
