import AppKit
import SwiftUI

// Nab's visual language: glass cells stacked inside a thin ring, DM Sans for words, SF Mono for
// numbers and shortcuts, neutral inks, and one ember colour for the primary action. Every view takes
// its colours, sizes and springs from here; a literal anywhere else is a bug.

enum Palette {
    static let ink = dynamic(dark: 0xE8EAED, light: 0x14161A)
    static let inkSecondary = dynamic(dark: 0xA8AEB6, light: 0x454B53)
    static let inkTertiary = dynamic(dark: 0xA0A7B0, light: 0x596067)
    static let hover = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.05, lightAlpha: 0.05)
    static let pressed = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.09, lightAlpha: 0.10)
    static let hairline = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.08, lightAlpha: 0.08)
    /// The 1 pt rim around the outer ring.
    static let rim = Color.white.opacity(0.16)
    /// Behind thumbnails while they load.
    static let well = dynamic(dark: 0x0A0B0D, light: 0x222529)
    /// Nab's action colour, used only for the primary button and work in flight.
    static let accent = dynamic(dark: 0xE0622A, light: 0xD4581F)
    static let accentWash = dynamic(dark: 0xE0622A, light: 0xD4581F, darkAlpha: 0.16, lightAlpha: 0.12)
    static let onAccent = Color.white
    static let ok = dynamic(dark: 0x62B48C, light: 0x236A4B)
    /// Failures shown inline.
    static let error = dynamic(dark: 0xF07178, light: 0xB3261E)
    /// Fill and border of round glass controls, at rest and while hovered.
    static let control = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.06, lightAlpha: 0.06)
    static let controlHover = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.12, lightAlpha: 0.10)
    static let controlBorder = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.08, lightAlpha: 0.10)
    static let controlBorderHover = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.18, lightAlpha: 0.18)

    static let nsAccent = NSColor(srgbRed: 0xE0 / 255, green: 0x62 / 255, blue: 0x2A / 255, alpha: 1)
    static let nsOK = NSColor(srgbRed: 0x62 / 255, green: 0xB4 / 255, blue: 0x8C / 255, alpha: 1)

    private static func dynamic(dark: UInt32, light: UInt32, darkAlpha: CGFloat = 1, lightAlpha: CGFloat = 1) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: isDark ? darkAlpha : lightAlpha)
            })
    }
}

@MainActor
enum Typeface {
    /// Section headers ("Tray"), tile labels.
    static var label: Font { DMSans.font(12, .semibold) }
    /// Meta lines, empty states, help text.
    static var meta: Font { DMSans.font(12) }
    /// Row titles.
    static var rowTitle: Font { DMSans.font(13, .semibold) }
    static var body: Font { DMSans.font(13) }
    /// Buttons and statuses.
    static var button: Font { DMSans.font(14, .semibold) }
    /// Transcript text in the library.
    static var reading: Font { DMSans.font(14) }
    /// Bold runs and headings inside chat answers.
    static var readingStrong: Font { DMSans.font(14, .semibold) }
    static var heading: Font { DMSans.font(15, .semibold) }
    /// Empty-state titles.
    static var title: Font { DMSans.font(17, .semibold) }
    /// Video title in the library reader.
    static var display: Font { DMSans.font(22, .semibold) }
    /// Durations, counts, shortcuts, timecodes.
    static let mono = Font.system(size: 12, design: .monospaced).monospacedDigit()
    /// Commands and prompts being edited.
    static let code = Font.system(size: 12, design: .monospaced)
    /// Timecodes cited inside an answer.
    static let cite = Font.system(size: 12.5, weight: .medium, design: .monospaced).monospacedDigit()

    static let readingLineSpacing: CGFloat = 5
}

enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let readingWidth: CGFloat = 660
}

enum Radius {
    static let thumb: CGFloat = 6
    static let row: CGFloat = 10
    /// Chat message bubbles.
    static let bubble: CGFloat = 14
    /// The chat composer.
    static let composer: CGFloat = 20
    static let cell: CGFloat = 18
    /// The ring around the cells: cell radius plus the ring's 8 pt.
    static let ring: CGFloat = 26
}

/// Fixed geometry of the menu bar panel, so its height is known before SwiftUI lays it out and the
/// window can grow downward in one step.
enum PanelMetrics {
    static let width: CGFloat = 360
    static let ring: CGFloat = 8
    static let gap: CGFloat = 8
    static let toolsHeight: CGFloat = 80
    static let footerHeight: CGFloat = 44
    static let cellPadding: CGFloat = 12
    static let headerHeight: CGFloat = 16
    static let rowHeight: CGFloat = 44
    static let rowSpacing: CGFloat = 4
    /// Between the tray list and the buttons under it.
    static let listGap: CGFloat = 10
    static let visibleRows = 4
    static let emptyHeight: CGFloat = 52
    static let buttonHeight: CGFloat = 40

    static func listHeight(rows: Int) -> CGFloat {
        let shown = min(rows, visibleRows)
        return shown == 0 ? emptyHeight : CGFloat(shown) * rowHeight + CGFloat(shown - 1) * rowSpacing
    }

    static func trayHeight(rows: Int) -> CGFloat {
        cellPadding + headerHeight + Space.s + listHeight(rows: rows) + listGap + buttonHeight + cellPadding
    }

    static func height(rows: Int) -> CGFloat {
        ring * 2 + toolsHeight + gap + trayHeight(rows: rows) + gap + footerHeight
    }
}
