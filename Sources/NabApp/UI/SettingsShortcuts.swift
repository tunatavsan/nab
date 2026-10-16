import AppKit
import NabCore
import SwiftUI

/// The Shortcuts group of the settings page: one row per action with its key caps and a recorder.
struct SettingsShortcutsSection: View {
    private let store = ShortcutStore.shared

    var body: some View {
        SettingsSection(
            title: "Shortcuts",
            footnote: "Work in any app. Esc cancels while recording, ⌫ clears the shortcut."
        ) {
            SettingsGroup {
                ForEach(ShortcutAction.allCases, id: \.self) { ShortcutRow(action: $0) }
                SettingsRow(title: "Restore Defaults") {
                    NabButton("Restore Defaults") { store.restoreDefaults() }
                        .disabled(store.map.isDefault && store.refused == nil)
                }
            }
        }
    }
}

private struct ShortcutRow: View {
    let action: ShortcutAction
    private let store = ShortcutStore.shared
    @State private var recorder = ShortcutRecorder()
    @State private var problem: String?

    var body: some View {
        SettingsRow(title: action.title, detail: detail, detailIsError: true) {
            HStack(spacing: Space.s) {
                if recorder.isRecording {
                    Text("Press the new shortcut").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                } else if let combo = store.combo(for: action) {
                    KeyCaps(combo, size: .medium)
                } else {
                    Text("None").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                }
                NabButton(recorder.isRecording ? "Cancel" : "Change") {
                    if recorder.isRecording { stop() } else { start() }
                }
            }
        }
        .onDisappear { stop() }
    }

    private var detail: String? {
        if let problem { return problem }
        return store.unavailable.contains(action) || store.refused == action ? "In use by another app" : nil
    }

    private func start() {
        problem = nil
        store.pause()
        recorder.start { event in handle(event) }
    }

    private func stop() {
        guard recorder.isRecording else { return }
        recorder.stop()
        store.resume()
    }

    private func handle(_ event: NSEvent) {
        let code = UInt32(event.keyCode)
        let mask = KeyCombo.carbonModifiers(eventFlags: event.modifierFlags.rawValue)
        if code == 53 && mask == 0 {  // Esc
            stop()
            return
        }
        stop()
        if code == 51 && mask == 0 {  // ⌫
            store.assign(nil, to: action)
            return
        }
        let combo = KeyCombo(keyCode: code, modifiers: mask)
        let result = store.validate(combo, for: action)
        guard result == .valid else {
            problem = result.message
            return
        }
        store.assign(combo, to: action)
    }
}

/// Listens for the next key press while a row is recording, and swallows it so nothing else reacts.
@MainActor @Observable
private final class ShortcutRecorder {
    private(set) var isRecording = false
    @ObservationIgnored private var monitor: Any?

    func start(_ onKey: @escaping (NSEvent) -> Void) {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            onKey(event)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }
}
