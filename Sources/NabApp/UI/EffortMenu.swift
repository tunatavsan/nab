import NabAI
import SwiftUI

/// The reasoning-effort chip beside the model chip. It changes the global setting, like the model menu; chats on
/// disk are untouched. Providers without effort levels show nothing.
struct EffortMenu: View {
    @Bindable var assistant: Assistant

    var body: some View {
        let settings = assistant.settings
        let levels = settings.kind.effortLevels
        if !levels.isEmpty {
            MenuChip(title: settings.effort.isEmpty ? "Default effort" : Self.name(settings.effort)) {
                Picker("Effort", selection: $assistant.settings.effort) {
                    Text("Default").tag("")
                    ForEach(levels, id: \.self) { Text(Self.name($0)).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                if settings.commandIgnoresEffort {
                    Divider()
                    Text("Your custom command ignores effort.")
                }
            }
            .help("Reasoning effort")
            .accessibilityLabel("Effort, \(settings.effort.isEmpty ? "default" : settings.effort)")
        }
    }

    static func name(_ level: String) -> String {
        switch level {
        case "xhigh": "Extra high"
        default: level.prefix(1).uppercased() + level.dropFirst()
        }
    }
}
