import NabCore
import SwiftUI

/// General: how the menu bar icon looks and where videos play.
struct SettingsGeneralSection: View {
    @AppStorage("menubar.iconStyle") private var iconStyle = MenuBarIconStyle.color.rawValue
    @AppStorage("player.target") private var playerTarget = PlayerTarget.nab

    var body: some View {
        SettingsSection(title: "General") {
            SettingsGroup {
                SettingsRow(
                    title: "Menu bar icon", detail: "Monochrome follows the menu bar: white on dark, black on light."
                ) {
                    SegmentedPicker(
                        [(MenuBarIconStyle.color.rawValue, "Color"), (MenuBarIconStyle.mono.rawValue, "Monochrome")],
                        selection: $iconStyle)
                }
                SettingsRow(title: "Play videos in", detail: PlayerTarget.detail(playerTarget)) {
                    PlayerTargetPicker(selection: $playerTarget)
                }
            }
        }
    }
}

/// Values of the `player.target` setting.
enum PlayerTarget {
    static let nab = "nab"
    static let browser = "browser"

    static func detail(_ target: String) -> String {
        target == browser
            ? "YouTube opens in your browser, so you watch signed in to your own account."
            : "Videos play inside Nab, next to the transcript and the chat."
    }
}

/// Nab or Browser.
struct PlayerTargetPicker: View {
    @Binding var selection: String

    var body: some View {
        SegmentedPicker([(PlayerTarget.nab, "Nab"), (PlayerTarget.browser, "Browser")], selection: $selection)
    }
}
