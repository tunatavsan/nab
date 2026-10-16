import AppKit
import NabAI
import NabCore
import ServiceManagement
import SwiftUI

/// The settings page: one centered column of sections, in the manner of System Settings.
struct SettingsView: View {
    @Bindable var assistant: Assistant
    let shortcutAvailable: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Settings")
                    .font(Typeface.largeTitle)
                    .tracking(Typeface.largeTitleTracking)
                    .foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                SettingsAICard(assistant: assistant)
                SettingsCaptureSection()
                SettingsShortcutsSection()
                SettingsPromptsSection(assistant: assistant)
            }
            .frame(width: 680, alignment: .leading)
            .padding(.vertical, Space.xl)
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: Capture

private struct SettingsCaptureSection: View {
    @AppStorage("autoCopy") private var autoCopy = true
    @AppStorage("sessionIdleMinutes") private var idleMinutes = 5
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        SettingsSection(title: "Capture", footnote: "Dubbed videos use the captions of the language you hear.") {
            SettingsGroup {
                SettingsToggleRow(
                    title: "Copy each video when it lands", detail: "The transcript goes straight to your clipboard.",
                    isOn: $autoCopy)
                SettingsRow(title: "New session after", detail: "Videos nabbed closer together join one session.") {
                    ValueStepper(value: $idleMinutes, range: 1...60) { "\($0) min" }
                }
                SettingsToggleRow(
                    title: "Open at login", detail: loginError, detailIsError: loginError != nil, isOn: $openAtLogin)
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

// MARK: Prompts

private struct SettingsPromptsSection: View {
    @Bindable var assistant: Assistant
    @State private var editing: Prompt?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Prompt: Equatable {
        case summary, system
    }

    var body: some View {
        SettingsSection(title: "Prompts") {
            SettingsGroup {
                promptRow(
                    .summary, title: "Summary prompt", detail: "Sent when you press Summarize.",
                    edited: assistant.settings.summaryPrompt != AISettings.defaultSummaryPrompt)
                if editing == .summary {
                    PromptEditor(
                        title: "Summary prompt", text: $assistant.settings.summaryPrompt,
                        original: AISettings.defaultSummaryPrompt,
                        note: "Sent when you press Summarize. {language} becomes the language you answer in.")
                }
                promptRow(
                    .system, title: "System prompt", detail: "How the assistant behaves in every chat.",
                    edited: assistant.settings.systemPrompt != AISettings.defaultSystemPrompt)
                if editing == .system {
                    PromptEditor(
                        title: "System prompt", text: $assistant.settings.systemPrompt,
                        original: AISettings.defaultSystemPrompt,
                        note: "How the assistant behaves in every chat. {language} becomes the language you answer in.")
                }
            }
        }
    }

    private func promptRow(_ prompt: Prompt, title: String, detail: String, edited: Bool) -> some View {
        SettingsRow(title: title, detail: edited ? "\(detail) Edited." : detail) {
            NabButton(editing == prompt ? "Done" : "Edit") {
                withAnimation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion)) {
                    editing = editing == prompt ? nil : prompt
                }
            }
            .accessibilityLabel(editing == prompt ? "Done editing \(title)" : "Edit \(title)")
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
        .settingsRowFrame()
    }
}
