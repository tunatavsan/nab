import NabCore
import SwiftUI

/// The welcome: up to four single-screen steps inside the library window. It opens by itself for an empty
/// library that has not seen it, and from the menu bar's right-click menu.
struct OnboardingView: View {
    let model: LibraryModel
    @AppStorage("onboarding.version") private var seen = 0
    @AppStorage("player.target") private var playerTarget = PlayerTarget.nab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let stepCount = 4
    private var step: Int { model.welcomeStep }

    var body: some View {
        VStack(spacing: Space.xl) {
            ZStack {
                content.id(step).transition(.page)
            }
            .frame(maxWidth: .infinity, minHeight: 300)
            dots
            footer
        }
        .frame(width: 560)
        .padding(.vertical, Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case 0: greeting
        case 1: OnboardingSetupStep(kind: .shortcuts, model: model)
        case 2: OnboardingSetupStep(kind: .ai, model: model)
        default: player
        }
    }

    // MARK: Steps

    private var greeting: some View {
        VStack(spacing: 18) {
            AppMark()
            heading("Welcome to Nab")
            Text("Nab turns a YouTube video into text an AI can read, and puts it on your clipboard.")
                .font(Typeface.reading).lineSpacing(5).foregroundStyle(Palette.inkSecondary)
                .multilineTextAlignment(.center).frame(maxWidth: 440)
            HStack(spacing: 10) {
                ZStack {
                    QuoteMark(part: .left).fill(Palette.accent)
                    QuoteMark(part: .right).fill(Palette.ink)
                }
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
                Text("Nab lives in the menu bar, top right. Click it to open the panel.")
                    .font(Typeface.meta).foregroundStyle(Palette.inkSecondary)
            }
            .padding(.horizontal, Space.l).frame(height: 40)
            .background(Palette.raised.opacity(0.7), in: .capsule)
            .overlay(Capsule().strokeBorder(Palette.line))
        }
    }

    private var player: some View {
        VStack(spacing: 18) {
            heading("Play videos in")
            VStack(spacing: Space.s) {
                option(
                    PlayerTarget.nab, "Nab", "Videos play inside Nab, next to the transcript.\nNothing else opens.")
                option(
                    PlayerTarget.browser, "Browser",
                    "YouTube opens in your browser, so you watch with your own account.\nYour subscriptions and history stay yours."
                )
            }
            .frame(maxWidth: 440)
            Text("You can change this later in Settings.").font(Typeface.meta).foregroundStyle(Palette.inkTertiary)
        }
    }

    private func option(_ value: String, _ title: String, _ text: String) -> some View {
        let on = playerTarget == value
        return Button {
            withAnimation(Motion.resolved(Motion.snap, reduceMotion: reduceMotion)) { playerTarget = value }
        } label: {
            HStack(spacing: Space.m) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Palette.accentInk : Palette.inkTertiary)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title).font(Typeface.cardTitle).foregroundStyle(Palette.ink)
                    Text(text).font(Typeface.meta).lineSpacing(3).foregroundStyle(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.raised.opacity(on ? 1 : 0.7), in: .rect(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(on ? Palette.accent : Palette.line, lineWidth: on ? 1.5 : 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Typeface.largeTitle).tracking(Typeface.largeTitleTracking).foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: Chrome

    private var dots: some View {
        HStack(spacing: 6) {
            ForEach(0..<Self.stepCount, id: \.self) { index in
                Circle().fill(index == step ? Palette.accent : Palette.lineStrong).frame(width: 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(Self.stepCount)")
    }

    private var footer: some View {
        HStack {
            NabButton("Skip", kind: .ghost, action: finish)
            Spacer()
            if step > 0 {
                NabButton("Back") { move(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
            }
            if step < Self.stepCount - 1 {
                NabButton("Next", kind: .primary) { move(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
            } else {
                NabButton("Done", kind: .primary, action: finish)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    private func move(_ delta: Int) {
        withAnimation(Motion.resolved(Motion.settle, reduceMotion: reduceMotion)) {
            model.welcomeStep = min(max(step + delta, 0), Self.stepCount - 1)
        }
    }

    /// Done and Skip both count as seen. Opened from the menu, the page goes back to where it was; shown in
    /// place of an empty home, writing the flag is enough.
    private func finish() {
        seen = Onboarding.currentVersion
        model.welcomeStep = 0
        guard model.route == .welcome else { return }
        if model.backStack.isEmpty { model.go(.home) } else { model.goBack() }
    }
}

/// The middle two steps: the four shortcuts as key caps, and the provider chooser that the first summary also shows.
private struct OnboardingSetupStep: View {
    enum Kind { case shortcuts, ai }
    let kind: Kind
    let model: LibraryModel

    var body: some View {
        VStack(spacing: 18) {
            Text(kind == .shortcuts ? "Shortcuts" : "AI").font(Typeface.largeTitle)
                .tracking(Typeface.largeTitleTracking).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            switch kind {
            case .shortcuts:
                Text("They work in any app.").font(Typeface.reading)
                    .foregroundStyle(Palette.inkSecondary)
                VStack(spacing: Space.m) {
                    ForEach(ShortcutAction.allCases, id: \.self) { action in
                        HStack(spacing: Space.l) {
                            Text(action.title).font(Typeface.reading).foregroundStyle(Palette.ink)
                            Spacer(minLength: Space.xl)
                            KeyCaps(ShortcutStore.shared.combo(for: action), size: .medium)
                        }
                    }
                }
                .frame(width: Space.drawerWidth)
                NabButton("Change…") { model.go(.settings) }
            case .ai:
                ProviderChooser { model.welcomeStep = 3 }
                    .frame(width: Space.readingWidth)
            }
        }
    }
}
