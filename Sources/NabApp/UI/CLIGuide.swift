import NabAI
import SwiftUI

/// Setup help for a command-line provider: looking, not installed, installed but signed out, or ready. Nab never
/// runs an install or sign-in command; it shows it for copying. No account name or e-mail is read or shown.
struct CLIGuide: View {
    let kind: ProviderKind
    /// Told every time the state settles, so a parent can enable its own buttons.
    var onState: (CLIState) -> Void = { _ in }
    @State private var state = CLIState.checking

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            switch state {
            case .checking:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for \(kind.shortTitle)…").font(Typeface.meta).foregroundStyle(Palette.inkSecondary)
                }
            case .notInstalled:
                Text("\(kind.shortTitle) is not installed.").font(Typeface.body).foregroundStyle(Palette.ink)
                ForEach(CLIStatus.installCommands(for: kind), id: \.self) { command in
                    commandLine(command)
                }
                if let url = CLIStatus.docsURL(for: kind) {
                    Link("Installation guide", destination: url).font(Typeface.meta)
                }
                NabButton("Check Again", kind: .ghost, action: recheck)
            case .signedOut:
                Text("\(kind.shortTitle) is installed but not signed in.")
                    .font(Typeface.body).foregroundStyle(Palette.ink)
                if let steps = CLIStatus.loginSteps(for: kind) {
                    Text(steps.text).font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
                    commandLine(steps.copy)
                }
                NabButton("Check Again", kind: .ghost, action: recheck)
            case .ready(let version, let method):
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(Typeface.iconSmall)
                    Text(readyText(version: version, method: method)).font(Typeface.meta)
                }
                .foregroundStyle(Palette.ok)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: kind) { await check() }
    }

    private func readyText(version: String?, method: String?) -> String {
        [kind.shortTitle + (version.map { " \($0)" } ?? ""), method ?? "Signed in"].joined(separator: " · ")
    }

    private func commandLine(_ command: String) -> some View {
        HStack(spacing: Space.s) {
            Text(command).font(Typeface.code).foregroundStyle(Palette.ink).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, Space.s).frame(height: 28)
                .background(Palette.field, in: .rect(cornerRadius: Radius.row, style: .continuous))
            NabButton("Copy") { Pasteboard.copy(command) }
        }
    }

    private func recheck() {
        state = .checking
        Task { await check() }
    }

    private func check() async {
        state = .checking
        let result = await CLIStatus.check(kind)
        guard !Task.isCancelled else { return }
        state = result
        onState(result)
    }
}
