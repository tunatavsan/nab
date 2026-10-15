import AppKit
import NabAI
import NabCore
import ServiceManagement
import SwiftUI

/// The settings page: the AI provider and model, capture behavior, shortcuts and prompts, as cards.
struct SettingsView: View {
    @Bindable var assistant: Assistant
    let shortcutAvailable: Bool
    var unavailableShortcuts: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings")
                    .font(Typeface.largeTitle)
                    .tracking(Typeface.largeTitleTracking)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                SettingsColumns(spacing: 20) {
                    SettingsAICard(assistant: assistant)
                    VStack(spacing: 20) {
                        SettingsCaptureCard()
                        SettingsShortcutsCard(
                            shortcutAvailable: shortcutAvailable, unavailableShortcuts: unavailableShortcuts)
                        SettingsPromptsCard(assistant: assistant)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Two columns of cards, the left one a quarter wider, each as tall as its content.
struct SettingsColumns: Layout {
    var spacing: CGFloat = 20

    private func widths(_ total: CGFloat) -> (left: CGFloat, right: CGFloat) {
        let free = max(total - spacing, 0)
        return (free * 1.25 / 2.25, free / 2.25)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let total = proposal.width ?? 880
        let (left, right) = widths(total)
        let heights = zip(subviews, [left, right]).map { $0.sizeThatFits(.init(width: $1, height: nil)).height }
        return CGSize(width: total, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (left, right) = widths(bounds.width)
        var x = bounds.minX
        for (view, width) in zip(subviews, [left, right]) {
            view.place(
                at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: .init(width: width, height: nil))
            x += width + spacing
        }
    }
}

/// A settings card: raised fill, hairline border, the large radius.
struct SettingsCard<Content: View>: View {
    var padding = EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .raisedCard(radius: Radius.cell)
    }
}

/// A hover and press fill for list rows and cards in the settings.
struct SettingsRowStyle: ButtonStyle {
    var selected = false
    var radius: CGFloat = 0
    /// Fill of the selected row; the neutral `selected` unless a page asks for lime.
    var tint: Color = Palette.selected
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? Palette.pressed : selected ? tint : hovering ? Palette.hover : .clear,
                in: .rect(cornerRadius: radius, style: .continuous)
            )
            .contentShape(.rect(cornerRadius: radius, style: .continuous))
            .onHover { hovering = $0 }
    }
}

/// The capsule-ish label of a settings menu: a value and a chevron.
struct SettingsMenuLabel: View {
    let title: String
    var chevron = true

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Typeface.button).lineLimit(1)
            if chevron { Image(systemName: "chevron.down").font(Typeface.iconMicro) }
        }
        .foregroundStyle(chevron ? Palette.ink : Palette.inkSecondary)
        .padding(.leading, 12)
        .padding(.trailing, chevron ? 10 : 12)
        .frame(height: 30)
        .background(Palette.control, in: .rect(cornerRadius: Radius.row, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.controlBorder))
    }
}

extension View {
    /// An editable field on a card.
    /// Pass the field's own focus binding when the caller reads it; otherwise the field tracks its own.
    func settingsField(focus: FocusState<Bool>.Binding? = nil) -> some View {
        modifier(SettingsFieldStyle(external: focus))
    }
}

/// The field chrome; the border turns lime while the field has focus.
private struct SettingsFieldStyle: ViewModifier {
    var external: FocusState<Bool>.Binding?
    @FocusState private var own: Bool
    private var focused: Bool { external?.wrappedValue ?? own }

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .focused(external ?? $own)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(Palette.field, in: .rect(cornerRadius: Radius.row, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(focused ? Palette.accent : Palette.line, lineWidth: focused ? 1.5 : 1)
            )
    }
}

/// A label with an optional line under it, and a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var detailIsError = false
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Typeface.body).foregroundStyle(Palette.ink)
                if let detail {
                    Text(detail).font(Typeface.meta).foregroundStyle(
                        detailIsError ? Palette.error : Palette.inkTertiary
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 34)
    }
}

// MARK: Capture

private struct SettingsCaptureCard: View {
    @AppStorage("autoCopy") private var autoCopy = true
    @AppStorage("sessionIdleMinutes") private var idleMinutes = 5
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Capture").font(Typeface.title).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Toggle(isOn: $autoCopy) {
                    rowText("Copy each video when it lands", "The transcript goes straight to your clipboard.")
                }
                .toggleStyle(NabToggleStyle())
                SettingsRow(title: "New session after", detail: "Videos nabbed closer together join one session.") {
                    ValueStepper(value: $idleMinutes, range: 1...60) { "\($0) min" }
                }
                SettingsRow(title: "Captions", detail: "Dubbed videos use the language you hear.") {
                    Text("Match the audio").font(Typeface.body).foregroundStyle(Palette.inkSecondary)
                }
                Toggle(isOn: $openAtLogin) {
                    rowText("Open at login", loginError, isError: loginError != nil)
                }
                .toggleStyle(NabToggleStyle())
                SettingsRow(title: "Library folder", detail: "Videos and chats are stored here.") {
                    NabButton("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([
                            LibraryStore.defaultFolder.deletingLastPathComponent()
                        ])
                    }
                }
            }
        }
        .onChange(of: openAtLogin) { _, on in setOpenAtLogin(on) }
    }

    private func rowText(_ title: String, _ detail: String?, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typeface.body).foregroundStyle(Palette.ink)
            if let detail {
                Text(detail).font(Typeface.meta).foregroundStyle(isError ? Palette.error : Palette.inkTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setOpenAtLogin(_ on: Bool) {
        guard on != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            openAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: Shortcuts

private struct SettingsShortcutsCard: View {
    let shortcutAvailable: Bool
    let unavailableShortcuts: [String]

    private static let shortcuts: [(keys: [String], title: String)] = [
        (["⌃", "⌥", "N"], "Nab the YouTube tab in front"),
        (["⌃", "⌥", "A"], "Copy the whole session"),
        (["⌃", "⌥", "S"], "Ask AI about the session"),
        (["⌃", "⌥", "X"], "Start a new session"),
    ]

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Shortcuts").font(Typeface.title).foregroundStyle(Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Work in any app.").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                }
                ForEach(Self.shortcuts, id: \.title) { shortcut in
                    SettingsRow(
                        title: shortcut.title, detail: available(shortcut.keys) ? nil : "In use by another app",
                        detailIsError: true
                    ) {
                        KeycapRow(shortcut.keys)
                    }
                }
            }
        }
    }

    private func available(_ keys: [String]) -> Bool {
        keys.last == "N" ? shortcutAvailable : !unavailableShortcuts.contains(keys.joined())
    }
}

// MARK: Prompts

private struct SettingsPromptsCard: View {
    @Bindable var assistant: Assistant
    @State private var open = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        SettingsCard(padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)) {
            VStack(alignment: .leading, spacing: 16) {
                Button {
                    withAnimation(Motion.resolved(Motion.settle, reduceMotion: reduceMotion)) { open.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prompts").font(Typeface.heading).foregroundStyle(Palette.ink)
                            Text("The summary prompt and the system prompt")
                                .font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                        }
                        Spacer(minLength: 8)
                        Text(open ? "Done" : "Edit").font(Typeface.meta)
                        Image(systemName: "chevron.right").font(Typeface.iconMicro).rotationEffect(
                            .degrees(open ? 90 : 0))
                    }
                    .foregroundStyle(Palette.inkSecondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(open ? "Hide prompts" : "Edit prompts")
                if open {
                    PromptEditor(
                        title: "Summary prompt", text: $assistant.settings.summaryPrompt,
                        original: AISettings.defaultSummaryPrompt,
                        note: "Sent when you press Summarize. {language} becomes the language you answer in.")
                    PromptEditor(
                        title: "System prompt", text: $assistant.settings.systemPrompt,
                        original: AISettings.defaultSystemPrompt,
                        note: "How the assistant behaves in every chat. {language} becomes the language you answer in.")
                }
            }
        }
    }
}

private struct PromptEditor: View {
    let title: String
    @Binding var text: String
    let original: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Typeface.label).foregroundStyle(Palette.inkTertiary)
                Spacer()
                if text != original { NabButton("Reset", kind: .ghost) { text = original } }
            }
            TextEditor(text: $text)
                .font(Typeface.code)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 130)
                .background(Palette.field, in: .rect(cornerRadius: Radius.row, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.row, style: .continuous).strokeBorder(Palette.line))
                .accessibilityLabel(title)
            Text(note).font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
        }
    }
}
