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

    /// The thin ring that holds the cells: a light blur behind the window and a 1 pt rim.
    func ring() -> some View {
        background(.ultraThinMaterial, in: .rect(cornerRadius: Radius.ring, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.ring, style: .continuous).strokeBorder(Palette.rim, lineWidth: 1)
            )
            .clipShape(.rect(cornerRadius: Radius.ring, style: .continuous))
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

/// A tool in the top cell: symbol over label. On hover the symbol lifts and glows, and the label
/// gives way to the tool's shortcut.
struct ToolTile: View {
    let symbol: String
    let title: String
    var shortcut: String?
    var enabled = true
    @Binding var hovered: String?
    let action: () -> Void

    private var isHovered: Bool { hovered == title }
    private var dimmed: Bool { hovered != nil && !isHovered }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .regular))
                    .frame(width: 26, height: 26)
                    .scaleEffect(isHovered ? 1.16 : 1)
                    .offset(y: isHovered ? -2 : 0)
                    .shadow(color: Palette.ink.opacity(isHovered ? 0.45 : 0), radius: 7)
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
            withAnimation(Motion.lift) { hovered = over ? title : (hovered == title ? nil : hovered) }
        }
    }
}

/// The full-width capsule for the one thing the panel is for.
struct PrimaryButton: View {
    let title: String
    let symbol: String
    var trailing: String?
    var enabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .scaleEffect(hovering ? 1.12 : 1)
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
            .background(Capsule().fill(Palette.accent.opacity(enabled ? (hovering ? 1 : 0.92) : 0.5)))
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: Palette.accent.opacity(hovering && enabled ? 0.45 : 0), radius: 10, y: 2)
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
                .font(.system(size: 13, weight: .semibold))
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
                .foregroundStyle(hovering ? Palette.ink : Palette.inkSecondary)
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
struct Thumb: View {
    let entry: Entry
    var width: CGFloat = 64

    var body: some View {
        ZStack {
            Palette.well
            AsyncImage(url: entry.thumbnailURL, transaction: Transaction(animation: Motion.snap)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill).transition(.opacity)
                }
            }
            switch entry.phase {
            case .fetching:
                Color.black.opacity(0.45)
                ProgressView().controlSize(.mini).tint(.white)
            case .failed:
                Color.black.opacity(0.55)
                Image(systemName: "exclamationmark").font(.system(size: 12, weight: .bold)).foregroundStyle(
                    Palette.accent)
            case .ready:
                EmptyView()
            }
        }
        .frame(width: width, height: width * 9 / 16)
        .clipShape(.rect(cornerRadius: Radius.thumb, style: .continuous))
        .animation(Motion.snap, value: entry.phase)
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
                    .phaseAnimator([1.0, 0.35]) { dot, value in
                        dot.opacity(value)
                    } animation: { _ in
                        .easeInOut(duration: 0.7)
                    }
            case .failed:
                Circle().strokeBorder(Palette.accent, lineWidth: 1.5).frame(width: 7, height: 7)
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
