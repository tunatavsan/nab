import AppKit
import NabCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Surfaces

extension View {
    /// One glass cell of the panel.
    func cell() -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: Radius.cell, style: .continuous))
    }

    /// The ring that holds the cells of a floating layer: Liquid Glass with a light tint and a 1 pt rim.
    func ring() -> some View { modifier(RingGlass()) }
}

private struct RingGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.ring, style: .continuous)
        content
            .glassEffect(.regular.tint(scheme == .dark ? .black.opacity(0.24) : .white.opacity(0.34)), in: shape)
            .overlay(shape.strokeBorder(Palette.rim, lineWidth: 1))
    }
}

// MARK: Text

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Typeface.label).foregroundStyle(Palette.inkTertiary)
    }
}

// MARK: Controls

/// A tool in the top cell: symbol over label. On hover the symbol lifts, and the label
/// gives way to the tool's shortcut.
struct ToolTile: View {
    let symbol: String
    let title: String
    var shortcut: String?
    var enabled = true
    @Binding var hovered: String?
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isHovered: Bool { hovered == title }
    private var dimmed: Bool { hovered != nil && !isHovered }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(Typeface.iconTool)
                    .frame(width: 26, height: 26)
                    .scaleEffect(isHovered && !reduceMotion ? 1.16 : 1)
                    .offset(y: isHovered && !reduceMotion ? -2 : 0)
                ZStack {
                    Text(title)
                        .font(Typeface.label)
                        .opacity(isHovered && shortcut != nil ? 0 : 1)
                    if let shortcut {
                        Text(shortcut)
                            .font(Typeface.mono)
                            .foregroundStyle(Palette.inkSecondary)
                            .offset(y: isHovered ? 0 : 3)
                            .opacity(isHovered ? 1 : 0)
                    }
                }
                .frame(height: 15)
            }
            .foregroundStyle(Palette.ink)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padding(.horizontal, Space.xs)
            .contentShape(.rect)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
        .opacity(enabled ? (dimmed ? 0.5 : 1) : 0.35)
        .onHover { over in
            withAnimation(Motion.resolved(Motion.lift, reduceMotion: reduceMotion)) {
                hovered = over ? title : (hovered == title ? nil : hovered)
            }
        }
    }
}

/// The full-width capsule for the panel's main action.
struct PrimaryButton: View {
    let title: String
    let symbol: String
    var trailing: String?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(Typeface.iconAction)
                    .scaleEffect(hovering && !reduceMotion ? 1.12 : 1)
                    .contentTransition(.symbolEffect(.replace))
                Text(title).font(Typeface.button)
                    .contentTransition(.opacity)
                if let trailing {
                    Text(trailing).font(Typeface.mono).opacity(0.75)
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity, minHeight: PanelMetrics.buttonHeight)
            .background(Capsule().fill(Palette.accent))
            .overlay(Capsule().fill(Palette.onAccent.opacity(hovering && enabled ? 0.08 : 0)))
            .opacity(enabled ? 1 : 0.5)
            .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .disabled(!enabled)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }
}

/// A 30 pt round icon button for panel headers and chat message actions.
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(Typeface.icon)
                .foregroundStyle(hovering ? Palette.ink : Palette.inkSecondary)
                .frame(width: 30, height: 30)
                .background(hovering ? Palette.hover : .clear, in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }
}

/// "Clear": a quiet text action that brightens on hover.
struct LinkButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title).font(Typeface.label)
                .foregroundStyle(hovering ? Palette.accentInk : Palette.inkSecondary)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
    }
}

/// A text button that answers a click with a short-lived confirmation ("Copied").
struct ConfirmingButton: View {
    let title: String
    let confirmation: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    @State private var confirmed = false

    var body: some View {
        Button {
            action()
            withAnimation(Motion.snap) { confirmed = true }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                withAnimation(Motion.settle) { confirmed = false }
            }
        } label: {
            Label(confirmed ? confirmation : title, systemImage: confirmed ? "checkmark" : systemImage)
                .contentTransition(.symbolEffect(.replace))
                .font(Typeface.button)
        }
        .buttonStyle(.glass)
        .tint(prominent ? Palette.accent : nil)
    }
}

// MARK: Entries

/// A 16:9 thumbnail. While the entry is fetching it dims and shows progress; a failure shows a mark.
struct Thumbnail: View {
    /// What sits in the top-left corner.
    enum Badge {
        case clipboard
        case index(Int)
    }

    let entry: Entry
    var width: CGFloat = 64
    var radius: CGFloat = Radius.thumbSmall
    var showsDuration = false
    var badge: Badge?
    @State private var loaded: NSImage?

    var body: some View {
        ZStack {
            Palette.well
            // A thumbnail seen before is drawn in the first frame; only one loading for the first time fades in.
            if let image = ThumbnailCache.cached(entry.thumbnailURL) ?? loaded {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill).transition(.opacity)
            }
            switch entry.phase {
            case .fetching:
                Palette.scrim
                ProgressView().controlSize(.mini).tint(Palette.onScrim)
            case .failed:
                Palette.scrimStrong
                Image(systemName: "exclamationmark").font(Typeface.iconBadge).foregroundStyle(Palette.error)
            case .ready:
                EmptyView()
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .overlay(alignment: .bottomTrailing) {
            if showsDuration, !entry.durationText.isEmpty {
                Text(entry.durationText)
                    .font(Typeface.mono)
                    .foregroundStyle(Palette.onScrim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.62), in: .rect(cornerRadius: Radius.chip, style: .continuous))
                    .padding(8)
            }
        }
        .overlay(alignment: .topLeading) {
            switch badge {
            case .clipboard: ClipboardPill().padding(8)
            case .index(let number):
                Text("\(number)")
                    .font(Typeface.mono)
                    .foregroundStyle(Palette.onScrim)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.62), in: .rect(cornerRadius: Radius.chip, style: .continuous))
                    .padding(8)
            case nil: EmptyView()
            }
        }
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line))
        .animation(Motion.snap, value: entry.phase)
        .accessibilityLabel(entry.title)
        .task(id: entry.thumbnailURL) {
            guard let url = entry.thumbnailURL, ThumbnailCache.cached(url) == nil else { return }
            let image = await ThumbnailCache.image(url)
            withAnimation(Motion.snap) { loaded = image }
        }
    }
}

/// Thumbnails kept in memory for the session, so a page that comes back shows them at once.
@MainActor
enum ThumbnailCache {
    private static let cache = NSCache<NSURL, NSImage>()

    static func cached(_ url: URL?) -> NSImage? { url.flatMap { cache.object(forKey: $0 as NSURL) } }

    static func image(_ url: URL) async -> NSImage? {
        if let hit = cached(url) { return hit }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
            (response as? HTTPURLResponse)?.statusCode == 200, let image = NSImage(data: data)
        else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

// MARK: Buttons and chips

/// The shared button: lime primary, bordered secondary, quiet ghost.
struct NabButton: View {
    enum Kind { case primary, secondary, ghost }
    enum Size { case regular, large }

    let title: String
    var shortcut: String?
    var kind = Kind.secondary
    var size = Size.regular
    var fullWidth = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(
        _ title: String, shortcut: String? = nil, kind: Kind = .secondary, size: Size = .regular,
        fullWidth: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.shortcut = shortcut
        self.kind = kind
        self.size = size
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Text(title).font(Typeface.button)
                if let shortcut {
                    Text(shortcut).font(Typeface.chip).opacity(kind == .primary ? 0.6 : 1)
                        .foregroundStyle(kind == .primary ? Palette.onAccent : Palette.inkTertiary)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, size == .large ? 16 : 12)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: size == .large ? 36 : 30)
            .background(fill, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.line)
                }
            }
            .contentShape(.rect(cornerRadius: Radius.row, style: .continuous))
        }
        .buttonStyle(PressableStyle(scale: 0.97))
        .opacity(enabled ? 1 : 0.45)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .accessibilityLabel(title)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Palette.onAccent
        case .secondary: Palette.ink
        case .ghost: hovering ? Palette.accentInk : Palette.inkSecondary
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: hovering ? Palette.accent.opacity(0.9) : Palette.accent
        case .secondary: hovering ? Palette.selected : Palette.raised
        case .ghost: hovering ? Palette.hover : .clear
        }
    }
}

/// One key of a shortcut.
struct Keycap: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(Typeface.mono)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 6)
            .frame(minWidth: 24, minHeight: 24)
            .background(Palette.control, in: .rect(cornerRadius: Radius.chip, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.chip, style: .continuous).strokeBorder(Palette.controlBorder)
            )
            .overlay(alignment: .bottom) {
                Capsule().fill(Palette.controlBorder).frame(height: 1).padding(.horizontal, 3)
            }
            .accessibilityLabel(text)
    }
}

struct KeycapRow: View {
    let keys: [String]
    init(_ keys: [String]) { self.keys = keys }

    var body: some View {
        HStack(spacing: Space.xs) { ForEach(Array(keys.enumerated()), id: \.offset) { Keycap($0.element) } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(keys.joined(separator: " "))
    }
}

/// A timecode in an answer or a transcript.
struct TimecodeChip: View {
    let label: String
    var active = false
    let action: () -> Void

    init(_ label: String, active: Bool = false, action: @escaping () -> Void) {
        self.label = label
        self.active = active
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Typeface.chip)
                .foregroundStyle(active ? Palette.onAccent : Palette.accentInk)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(
                    active ? Palette.accent : Palette.accentWash,
                    in: .rect(cornerRadius: Radius.chip, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(PressableStyle(scale: 0.95))
        .accessibilityLabel("Timecode \(label)")
    }
}

struct ClipboardPill: View {
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "checkmark").font(Typeface.iconMicro)
            Text("On clipboard").font(Typeface.label)
        }
        .foregroundStyle(Palette.onAccent)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Palette.accent, in: .capsule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("On clipboard")
    }
}

struct LiveDot: View {
    var body: some View {
        Circle().fill(Palette.accent).frame(width: 7, height: 7).accessibilityLabel("Live")
    }
}

/// A row of mutually exclusive options.
struct SegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    init(_ options: [(value: Value, title: String)], selection: Binding<Value>) {
        self.options = options
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(Motion.snap) { selection = option.value }
                } label: {
                    Text(option.title)
                        .font(on ? Typeface.label : Typeface.meta)
                        .foregroundStyle(on ? Palette.onAccent : Palette.inkSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(
                            on ? Palette.accent : .clear, in: .rect(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.line))
    }
}

/// A capsule that opens a menu, such as the model picker.
struct MenuChip<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Menu {
            content
        } label: {
            HStack(spacing: 5) {
                Text(title).font(Typeface.meta)
                Image(systemName: "chevron.down").font(Typeface.iconMicro)
            }
            .foregroundStyle(Palette.inkSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Palette.control, in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.controlBorder))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(title)
    }
}

struct NabToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Motion.snap) { configuration.isOn.toggle() }
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: Space.m)
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule().fill(configuration.isOn ? Palette.accent : Palette.controlHover)
                    Circle()
                        .fill(Color.white)
                        .overlay(Circle().strokeBorder(Palette.line))
                        .frame(width: 16, height: 16)
                        .padding(2)
                }
                .frame(width: 34, height: 20)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

/// "− 5 min +"
struct ValueStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    let format: (Int) -> String

    init(value: Binding<Int>, range: ClosedRange<Int>, step: Int = 1, format: @escaping (Int) -> String) {
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        HStack(spacing: 0) {
            button("minus", help: "Decrease") { value = max(range.lowerBound, value - step) }
                .disabled(value <= range.lowerBound)
            Text(format(value))
                .font(Typeface.mono)
                .foregroundStyle(Palette.ink)
                .frame(minWidth: 52)
                .contentTransition(.numericText())
            button("plus", help: "Increase") { value = min(range.upperBound, value + step) }
                .disabled(value >= range.upperBound)
        }
        .frame(height: 30)
        .background(Palette.raised, in: .rect(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.line))
        .animation(Motion.snap, value: value)
        .accessibilityElement(children: .contain)
        .accessibilityValue(format(value))
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(Typeface.icon).frame(width: 30, height: 30).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Palette.inkSecondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

// MARK: Surfaces and headers

extension View {
    /// The content card of the window.
    func surfaceCard() -> some View {
        background(Palette.surface, in: .rect(cornerRadius: Radius.cell, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.cell, style: .continuous).strokeBorder(Palette.line))
            .clipShape(.rect(cornerRadius: Radius.cell, style: .continuous))
    }

    /// A card or cell sitting on the surface.
    func raisedCard(radius: CGFloat = Radius.card) -> some View {
        background(Palette.raised, in: .rect(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Palette.line))
    }
}

struct SectionHeader: View {
    let title: String
    var detail: String?
    var live = false

    init(title: String, detail: String? = nil, live: Bool = false) {
        self.title = title
        self.detail = detail
        self.live = live
    }

    var body: some View {
        HStack(spacing: 10) {
            if live { LiveDot() }
            Text(title).font(Typeface.title).foregroundStyle(Palette.ink)
            if let detail { Text(detail).font(Typeface.meta).foregroundStyle(Palette.inkTertiary) }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The toolbar's search field. It only looks like one; a click opens the palette.
struct SearchPill: View {
    var placeholder = "Search videos, chats and transcripts"
    let action: () -> Void
    @State private var hovering = false

    init(placeholder: String = "Search videos, chats and transcripts", action: @escaping () -> Void) {
        self.placeholder = placeholder
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(Typeface.icon)
                Text(placeholder).font(Typeface.body).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("⌘K")
                    .font(Typeface.mono)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Palette.controlBorder))
            }
            .foregroundStyle(Palette.inkTertiary)
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(width: 440, height: 32)
            .background(hovering ? Palette.selected : Palette.raised, in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.line))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { over in withAnimation(Motion.snap) { hovering = over } }
        .help("Search (⌘K)")
        .accessibilityLabel(placeholder)
    }
}

/// Where an entry stands, for list rows without a thumbnail.
struct PhaseMark: View {
    let phase: Entry.Phase
    var body: some View {
        ZStack {
            switch phase {
            case .fetching:
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                    .pulsing(low: 0.35, duration: 0.7)
            case .failed:
                Circle().strokeBorder(Palette.error, lineWidth: 1.5).frame(width: 7, height: 7)
            case .ready:
                Color.clear
            }
        }
        .frame(width: 8, height: 8)
        .animation(Motion.snap, value: phase)
    }
}

extension Entry {
    var metaLine: String {
        switch phase {
        case .fetching: return "Fetching transcript…"
        case .failed: return failure ?? "Failed"
        case .ready:
            var parts: [String] = []
            if let author = capture?.author { parts.append(author) }
            if let transcript = capture?.transcript {
                parts.append("\(transcript.wordCount.formatted()) words")
            } else {
                parts.append("no transcript")
            }
            return parts.joined(separator: " · ")
        }
    }

    var durationText: String { capture?.duration.map(Timecode.string) ?? "" }
}

// MARK: Output

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
enum Exporter {
    /// Asks where to save, then writes the context pack as Markdown.
    static func save(_ captures: [Capture]) {
        guard !captures.isEmpty else { return }
        NSApp.activate()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue =
            (captures.count == 1 ? captures[0].title : "Nab — \(captures.count) videos")
            .replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ContextPack.render(captures).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

/// The Nab mark: two closing quotes, each one filled shape (a round head flowing into a tapered tail, down-left).
/// Drawn on a 64 × 64 grid, optically centred; the icon artwork is the same glyph.
struct QuoteMark: Shape {
    enum Part { case both, left, right }
    var part = Part.both

    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 64
        let origin = CGPoint(x: rect.midX - 32 * k, y: rect.midY - 32 * k)
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: origin.x + x * k, y: origin.y + y * k) }
        var path = Path()
        let heads: [CGFloat] =
            switch part {
            case .both: [21.5, 45.5]
            case .left: [21.5]
            case .right: [45.5]
            }
        for cx in heads {
            let cy: CGFloat = 25
            path.move(to: p(cx - 10, cy))
            path.addArc(center: p(cx, cy), radius: 10 * k, startAngle: .degrees(180), endAngle: .zero, clockwise: false)
            path.addCurve(to: p(cx - 13, cy + 25), control1: p(cx + 10, cy + 11), control2: p(cx + 4, cy + 19.5))
            path.addCurve(to: p(cx - 10, cy), control1: p(cx - 7, cy + 16), control2: p(cx - 10, cy + 10))
            path.closeSubpath()
        }
        return path
    }
}
