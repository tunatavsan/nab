import NabAI
import NabCore
import SwiftUI

/// What the library shows before anything is nabbed.
struct FirstRunView: View {
    let model: LibraryModel
    @State private var link = ""
    @FocusState private var focused: Bool

    private var center: CaptureCenter { model.center }
    private var settings: AISettings { model.assistant.settings }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                intro
                pasteField
                steps
                aiStatus
                Text("Nab lives in the menu bar. You can close this window.")
                    .font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
            }
            .frame(width: 640)
            .padding(.vertical, Space.l)
            .frame(maxWidth: .infinity, minHeight: 0)
        }
        .defaultScrollAnchor(.center)
        .scrollBounceBehavior(.basedOnSize)
    }

    private var intro: some View {
        VStack(spacing: 14) {
            AppMark()
            Text("Nab a video to start").font(Typeface.largeTitle).tracking(Typeface.largeTitleTracking)
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(
                "Nab turns a YouTube video into text an AI can read. It puts the transcript on your clipboard, ready to paste anywhere."
            )
            .font(Typeface.reading).lineSpacing(5).foregroundStyle(Palette.inkSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 500)
        }
    }

    private var pasteField: some View {
        HStack(spacing: 10) {
            TextField("Paste a YouTube link", text: $link)
                .textFieldStyle(.plain)
                .font(Typeface.reading)
                .focused($focused)
                .onSubmit(nab)
                .accessibilityLabel("YouTube link")
            NabButton("Nab", kind: .primary, size: .large, action: nab)
                .disabled(link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.leading, 18).padding(.trailing, 6)
        .frame(height: 52)
        .background(Palette.control, in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused ? Palette.accent : Palette.controlBorder, lineWidth: focused ? 1.5 : 1)
        )
    }

    private func nab() {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        center.add(linksIn: text)
        link = ""
    }

    private var steps: some View {
        HStack(alignment: .top, spacing: Space.m) {
            if center.shortcutAvailable {
                step(
                    ["⌃", "⌥", "N"], "Nab the tab you’re watching",
                    "Works from any app while a YouTube tab is in front.")
            } else {
                step(
                    ["⌃", "⌥", "N"], "⌃⌥N is in use by another app",
                    "Use Front Tab in the menu bar panel to nab the tab you’re watching.")
            }
            step(["⌘", "V"], "Paste into any AI", "Claude, ChatGPT, a notes app. Nab already copied it.")
            step(["⌃", "⌥", "S"], "Or ask right here", "A floating window answers about everything in the session.")
        }
    }

    private func step(_ keys: [String], _ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            KeycapRow(keys)
            Text(title).font(Typeface.cardTitle).foregroundStyle(Palette.ink)
            Text(text).font(Typeface.meta).lineSpacing(3).foregroundStyle(Palette.inkTertiary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
        .padding(Space.l)
        .background(Palette.raised.opacity(0.7), in: .rect(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.line))
        .accessibilityElement(children: .combine)
    }

    private var aiStatus: some View {
        let problem = model.assistant.client.problem
        let provider =
            settings.kind.title.split(separator: "(").first.map { $0.trimmingCharacters(in: .whitespaces) }
            ?? settings.kind.title
        return HStack(spacing: 10) {
            Image(systemName: "sparkle").font(.system(size: 12, weight: .bold))
                .foregroundStyle(problem == nil ? Palette.accentInk : Palette.inkTertiary)
                .accessibilityHidden(true)
            Group {
                if let problem {
                    Text("AI not set up · \(problem)")
                } else {
                    HStack(spacing: 0) {
                        Text("AI ready · ").foregroundStyle(Palette.inkSecondary)
                        Text(provider).foregroundStyle(Palette.ink)
                        if !settings.model.isEmpty {
                            Text(" · \(ModelNames.display(settings.model))").foregroundStyle(Palette.inkSecondary)
                        }
                    }
                }
            }
            .font(Typeface.button.weight(.regular))
            .lineLimit(1)
            Spacer(minLength: 0)
            NabButton("Change", kind: .ghost) { model.go(.settings) }
                .help("Choose the AI model in Settings")
        }
        .padding(.leading, Space.l).padding(.trailing, 6)
        .frame(height: 48)
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Palette.line))
    }
}

/// The Nab mark on a dark tile.
private struct AppMark: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous).fill(
                Color(red: 0x16 / 255, green: 0x21 / 255, blue: 0x3B / 255))
            RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Palette.lineStrong)
            ZStack {
                QuoteMark(part: .left).fill(Palette.accent)
                QuoteMark(part: .right).fill(Color(white: 0.95))
            }
            .frame(width: 54, height: 54)
        }
        .frame(width: 88, height: 88)
        .accessibilityLabel("Nab")
    }
}
