import AppKit
import NabCore
import SwiftUI

/// What the shortcuts just did, under the menu bar icon, without taking focus: one glass card that is
/// fetching, on the clipboard, a stack for a session of several videos, or a plain message. The window
/// drops in and lifts out with the same Core Animation spring as the panel; the card inside changes with a
/// SwiftUI spring and the window's height follows it.
@MainActor
final class RackController {
    private let panel: FloatingPanel
    private let center: CaptureCenter
    private let anchor: () -> NSRect?
    private var shrink: Task<Void, Never>?
    private let presentation = RackPresentation()

    init(
        center: CaptureCenter, anchor: @escaping () -> NSRect?, openLibrary: @escaping (String?) -> Void,
        openSession: @escaping () -> Void, summarize: @escaping ([String]) -> Void
    ) {
        self.center = center
        self.anchor = anchor
        let presentation = presentation
        panel = FloatingPanel(
            size: NSSize(width: RackMetrics.width, height: RackMetrics.windowHeight(.message)), level: .statusBar
        ) {
            RackView(
                center: center, presentation: presentation, openLibrary: openLibrary, openSession: openSession,
                summarize: summarize)
        }
        observe { [weak self] in self?.sync() }
    }

    private func sync() {
        let visible = center.toast != nil
        let target = RackMetrics.windowHeight(RackCard.resolve(toast: center.toast, session: center.session).kind)
        if visible {
            shrink?.cancel()
            if target >= panel.frame.height || !panel.isVisible {
                // Growing: the window is tall enough before the card starts to move in.
                panel.setHeight(target)
            } else {
                // Shrinking: wait until the leaving card has settled.
                shrink = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(RackMetrics.settleDelay))
                    guard !Task.isCancelled, let self else { return }
                    self.panel.setHeight(
                        RackMetrics.windowHeight(
                            RackCard.resolve(toast: self.center.toast, session: self.center.session).kind))
                }
            }
            if !panel.isVisible {
                // The hidden window still shows the last card; a fresh view opens straight on the new one, so
                // the window's spring is the only motion instead of a crossfade on top of it.
                presentation.generation += 1
                panel.place(below: anchor())
            }
            panel.present()
        } else {
            shrink?.cancel()
            panel.dismiss()
        }
    }
}

/// Bumped each time the rack opens from hidden.
@MainActor @Observable
final class RackPresentation {
    var generation = 0
}

/// Which card the rack shows, derived from the latest toast and the open session.
struct RackCard: Equatable {
    enum Kind: Equatable { case fetching, ready, stack, message }

    var kind: Kind
    /// The video the card is about, if any.
    var entry: Entry?

    @MainActor
    static func resolve(toast: CaptureCenter.Toast?, session: [Entry]) -> RackCard {
        guard let toast else { return RackCard(kind: .message) }
        let match = session.first { $0.title == toast.title && $0.thumbnailURL == toast.thumbnail }
        switch toast.tone {
        case .working:
            // Another video may have landed while this one still runs; the card is about the one in flight.
            let running = session.first { $0.phase == .fetching } ?? match
            return running.map { RackCard(kind: .fetching, entry: $0) } ?? RackCard(kind: .message)
        case .done where match != nil:
            return RackCard(kind: session.count > 1 ? .stack : .ready, entry: match)
        case .failed where match != nil:
            return RackCard(kind: .ready, entry: match)
        default:
            return RackCard(kind: .message)
        }
    }
}

/// Window and card sizes.
enum RackMetrics {
    static let width: CGFloat = 360
    /// Space around the card, where the window's shadow falls.
    static let inset: CGFloat = 8
    static let cardPadding: CGFloat = 12
    static let thumbWidth: CGFloat = 64
    static let thumbHeight: CGFloat = 36
    /// How far each of the two cards peeking under the stack shows.
    static let peek: CGFloat = 6
    /// About how long the card springs take to come to rest.
    static let settleDelay = 0.5

    static func cardHeight(_ kind: RackCard.Kind) -> CGFloat {
        switch kind {
        case .fetching: cardPadding * 2 + thumbHeight + 10 + 3
        case .ready: 78
        case .message: cardPadding * 2 + thumbHeight
        case .stack: cardPadding * 2 + 34 + 10 + 30 + peek * 2
        }
    }

    static func windowHeight(_ kind: RackCard.Kind) -> CGFloat { inset * 2 + cardHeight(kind) }
}

private struct RackView: View {
    let center: CaptureCenter
    let presentation: RackPresentation
    let openLibrary: (String?) -> Void
    let openSession: () -> Void
    let summarize: ([String]) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Kept so the content stays while the window lifts out.
    @State private var lastToast: CaptureCenter.Toast?
    @State private var lastSession: [Entry] = []

    var body: some View {
        let live = center.toast != nil
        let toast = center.toast ?? lastToast
        let session = live ? center.session : lastSession
        let card = RackCard.resolve(toast: toast, session: session)
        VStack(spacing: 0) {
            if let toast {
                content(card, toast: toast, session: session)
                    .id(card.kind)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .padding(RackMetrics.inset)
        .frame(width: RackMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .onHover { center.holdToast($0) }
        .animation(Motion.resolved(Motion.settle, reduceMotion: reduceMotion), value: card.kind)
        .onChange(of: center.toast) { if let new = center.toast { lastToast = new } }
        .onChange(of: center.session) { if center.toast != nil { lastSession = center.session } }
        .onAppear {
            lastToast = center.toast
            lastSession = center.session
        }
        .id(presentation.generation)
    }

    @ViewBuilder private func content(_ card: RackCard, toast: CaptureCenter.Toast, session: [Entry]) -> some View {
        let copied = card.entry.map { center.copiedIDs.contains($0.id) } ?? false
        switch card.kind {
        case .fetching:
            FetchingCard(entry: card.entry, toast: toast, reduceMotion: reduceMotion)
                .onTapGesture { open(card.entry?.id) }
        case .ready:
            ReadyCard(entry: card.entry, toast: toast, copied: copied)
                .onTapGesture { open(card.entry?.id) }
        case .stack:
            StackCard(
                session: session, copied: !center.copiedIDs.isDisjoint(with: session.map(\.id)),
                shortcuts: RackText.hints(map: ShortcutStore.shared.map, unavailable: ShortcutStore.shared.unavailable)
                    .map(\.action),
                copyAll: { center.copySession() },
                askAI: { summarize(center.sessionSummaryIDs()) }
            )
            .onTapGesture {
                center.dismissToast()
                openSession()
            }
        case .message:
            MessageCard(toast: toast)
                .onTapGesture { center.dismissToast() }
        }
    }

    private func open(_ id: String?) {
        center.dismissToast()
        if let id { openLibrary(id) }
    }
}

// MARK: Cards

private struct RackThumb: View {
    let url: URL?
    var width: CGFloat = RackMetrics.thumbWidth
    var radius: CGFloat = Radius.thumbSmall

    var body: some View {
        ZStack {
            Palette.well
            AsyncImage(url: url) {
                $0.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color.clear
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line))
        .accessibilityHidden(true)
    }
}

/// The glass every card sits on.
private struct CardSurface<Content: View>: View {
    let kind: RackCard.Kind
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(RackMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: RackMetrics.cardHeight(kind))
            .cell()
    }
}

private struct FetchingCard: View {
    let entry: Entry?
    let toast: CaptureCenter.Toast
    let reduceMotion: Bool

    var body: some View {
        CardSurface(kind: .fetching) {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    RackThumb(url: entry?.thumbnailURL ?? toast.thumbnail)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fetching captions…").font(Typeface.meta).foregroundStyle(Palette.inkSecondary)
                        Text(entry?.title ?? toast.title)
                            .font(Typeface.rowTitle).foregroundStyle(Palette.ink).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                IndeterminateBar(still: reduceMotion)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fetching captions, \(entry?.title ?? toast.title)")
        .frameProbe("toast.update", Double(toast.pulse))
    }
}

private struct ReadyCard: View {
    let entry: Entry?
    let toast: CaptureCenter.Toast
    let copied: Bool

    private var failed: Bool { toast.tone == .failed }

    var body: some View {
        CardSurface(kind: .ready) {
            HStack(spacing: 10) {
                RackThumb(url: entry?.thumbnailURL ?? toast.thumbnail)
                VStack(alignment: .leading, spacing: 2) {
                    headline
                    Text(entry?.title ?? toast.title)
                        .font(Typeface.rowTitle).foregroundStyle(Palette.ink).lineLimit(1)
                    Text(detail)
                        .font(Typeface.meta).foregroundStyle(failed ? Palette.error : Palette.inkTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .frameProbe("toast.update", Double(toast.pulse))
    }

    private var detail: String {
        if failed { return entry?.failure ?? toast.detail }
        return entry?.detailLine ?? toast.detail
    }

    @ViewBuilder private var headline: some View {
        HStack(spacing: 6) {
            if failed {
                Image(systemName: "exclamationmark.circle.fill").font(Typeface.icon).foregroundStyle(Palette.error)
                Text("Couldn't fetch captions").foregroundStyle(Palette.error)
            } else {
                CheckDot()
                if toast.detail.hasPrefix("Already") {
                    Text("Already in your session").foregroundStyle(Palette.ink)
                } else if copied {
                    HStack(spacing: 0) {
                        Text("On clipboard").foregroundStyle(Palette.ink)
                        Text(" · ⌘V into any AI").foregroundStyle(Palette.inkTertiary)
                    }
                } else {
                    Text(RackText.clipboardTitle(copied: false)).foregroundStyle(Palette.ink)
                }
            }
        }
        .font(Typeface.meta)
        .lineLimit(1)
    }
}

private struct MessageCard: View {
    let toast: CaptureCenter.Toast

    var body: some View {
        CardSurface(kind: .message) {
            HStack(spacing: 10) {
                if toast.tone == .failed {
                    Image(systemName: "exclamationmark.circle.fill").font(Typeface.iconMark).foregroundStyle(
                        Palette.error)
                } else if toast.tone == .done {
                    CheckDot(size: 18)
                } else {
                    LimeSpinner(size: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(toast.title).font(Typeface.rowTitle).foregroundStyle(Palette.ink).lineLimit(1)
                    if !toast.detail.isEmpty {
                        Text(toast.detail)
                            .font(Typeface.meta)
                            .foregroundStyle(toast.tone == .failed ? Palette.error : Palette.inkTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
        .frameProbe("toast.update", Double(toast.pulse))
    }
}

private struct StackCard: View {
    let session: [Entry]
    let copied: Bool
    let shortcuts: [ShortcutAction]
    let copyAll: () -> Void
    let askAI: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            peekCard(inset: 20, opacity: 0.55).offset(y: RackMetrics.peek * 2)
            peekCard(inset: 10, opacity: 0.8).offset(y: RackMetrics.peek)
            front
        }
        .frame(height: RackMetrics.cardHeight(.stack), alignment: .top)
        .frameProbe("rack.insert", Double(session.count))
    }

    private func peekCard(inset: CGFloat, opacity: Double) -> some View {
        Color.clear
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.cell, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.cell, style: .continuous).strokeBorder(Palette.line))
            .frame(height: RackMetrics.cardHeight(.stack) - RackMetrics.peek * 2)
            .padding(.horizontal, inset)
            .opacity(opacity)
    }

    private var front: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                stackedThumbs
                VStack(alignment: .leading, spacing: 2) {
                    Text(RackText.header(count: session.count))
                        .font(Typeface.rowTitle).foregroundStyle(Palette.ink)
                        .contentTransition(.numericText())
                    Text(RackText.stackSubtitle(copied: copied))
                        .font(Typeface.meta).foregroundStyle(Palette.inkSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 34)
            HStack(spacing: 6) {
                RackButton(title: "Copy all", combo: combo(.copySession), action: copyAll)
                RackButton(title: "Ask AI", combo: combo(.summarize), primary: true, action: askAI)
            }
        }
        .padding(RackMetrics.cardPadding)
        .frame(height: RackMetrics.cardHeight(.stack) - RackMetrics.peek * 2)
        .cell()
    }

    private func combo(_ action: ShortcutAction) -> KeyCombo? {
        shortcuts.contains(action) ? ShortcutStore.shared.combo(for: action) : nil
    }

    /// Up to three thumbnails fanned out, the newest in front at the bottom left.
    private var stackedThumbs: some View {
        let shown = Array(session.prefix(3))
        return ZStack(alignment: .topLeading) {
            ForEach(Array(shown.enumerated().reversed()), id: \.element.id) { index, entry in
                RackThumb(url: entry.thumbnailURL, width: 44, radius: 5)
                    .offset(x: CGFloat(index) * 6, y: 8 - CGFloat(index) * 4)
            }
        }
        .frame(width: 60, height: 34, alignment: .topLeading)
    }
}

private struct RackButton: View {
    let title: String
    var combo: KeyCombo?
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(Typeface.button)
                KeyCaps(combo, surface: primary ? .accent : .neutral)
            }
            .foregroundStyle(primary ? Palette.onAccent : Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(fill, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.line)
                }
            }
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .accessibilityLabel(title)
    }

    private var fill: Color {
        if primary { return hovering ? Palette.accent.opacity(0.9) : Palette.accent }
        return hovering ? Palette.selected : Palette.raised
    }
}

/// The lime circle with a check, as in "On clipboard".
private struct CheckDot: View {
    var size: CGFloat = 14

    var body: some View {
        Circle().fill(Palette.accent)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "checkmark").font(.system(size: size * 0.55, weight: .heavy))
                    .foregroundStyle(Palette.onAccent)
            }
            .accessibilityHidden(true)
    }
}

/// A thin track with a lime segment sliding along it; a fixed share when Reduce Motion is on.
private struct IndeterminateBar: View {
    let still: Bool

    var body: some View {
        TimelineView(.animation(paused: still)) { timeline in
            GeometryReader { proxy in
                let share = 0.4
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                let travel = proxy.size.width * (1 - share)
                let phase = still ? 0.0 : (t < 0.5 ? t * 2 : 2 - t * 2)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.line)
                    Capsule().fill(Palette.accentInk)
                        .frame(width: proxy.size.width * share)
                        .offset(x: travel * (still ? 0.1 : phase))
                }
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}
