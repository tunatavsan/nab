import AppKit
import SwiftUI

// Nab's visual language: a solid dark (or light) surface inside the window, glass only on floating layers,
// DM Sans for words, SF Mono for numbers and shortcuts, neutral inks, and one lime accent that marks
// the primary action, live work and the current selection. Colors, type, radii and motion come from this
// folder; one-off layout numbers (a padding, a frame) may stay in the view.

enum Palette {
    /// Window background and the toolbar area.
    static let window = dynamic(dark: 0x101216, light: 0xECEEF1)
    /// The main content card.
    static let surface = dynamic(dark: 0x14161B, light: 0xFFFFFF)
    /// Side columns and the transcript drawer inside the surface.
    static let sunken = dynamic(dark: 0x121419, light: 0xF6F7F8)
    /// Cards and cells on the surface.
    static let raised = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.045, lightAlpha: 0.035)
    /// Hairlines and card borders.
    static let line = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.07, lightAlpha: 0.08)
    /// Selected card border and the rim of floating layers.
    static let lineStrong = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.14, lightAlpha: 0.16)
    /// Selected row or card fill, and the "on" segment of a picker.
    static let selected = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.08, lightAlpha: 0.06)
    static let hover = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.05, lightAlpha: 0.05)
    static let pressed = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.09, lightAlpha: 0.10)

    static let ink = dynamic(dark: 0xE8EAED, light: 0x14161A)
    static let inkSecondary = dynamic(dark: 0xA8AEB6, light: 0x454B53)
    static let inkTertiary = dynamic(dark: 0x7F868F, light: 0x6B727B)

    /// The 1 pt rim around the outer ring.
    static let rim = Color.white.opacity(0.16)
    /// Behind thumbnails while they load.
    static let well = dynamic(dark: 0x0A0B0D, light: 0x222529)
    /// Lime fills: the primary action, the live dot, the current selection.
    static let accent = dynamic(dark: 0xC6F06A, light: 0xC6F06A)
    /// Text or glyphs on a lime fill.
    static let onAccent = dynamic(dark: 0x0F1115, light: 0x0F1115)
    /// Lime as text or a line on a neutral surface.
    static let accentInk = dynamic(dark: 0xC6F06A, light: 0x4B7A0E)
    /// Timecode chips and search-match highlights.
    static let accentWash = dynamic(dark: 0xC6F06A, light: 0xC6F06A, darkAlpha: 0.14, lightAlpha: 0.30)
    /// Spinner tracks and secondary ticks.
    static let accentSoft = dynamic(dark: 0xC6F06A, light: 0x4B7A0E, darkAlpha: 0.28, lightAlpha: 0.30)
    /// Over a thumbnail while it loads or has failed, and the ink drawn on it.
    static let scrim = Color.black.opacity(0.45)
    static let scrimStrong = Color.black.opacity(0.55)
    static let onScrim = Color.white
    static let ok = dynamic(dark: 0x62B48C, light: 0x236A4B)
    /// Failures shown inline.
    static let error = dynamic(dark: 0xF07178, light: 0xB3261E)
    /// Behind text editors.
    static let field = Color.primary.opacity(0.06)
    /// Fill and border of round glass controls, at rest and while hovered.
    static let control = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.06, lightAlpha: 0.06)
    static let controlHover = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.12, lightAlpha: 0.10)
    static let controlBorder = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.08, lightAlpha: 0.10)
    static let controlBorderHover = dynamic(dark: 0xFFFFFF, light: 0x14181E, darkAlpha: 0.18, lightAlpha: 0.18)

    /// Template images use only alpha, so the ink color is ignored.
    static let nsTemplateInk = NSColor.black
    static let nsAccent = NSColor(srgbRed: 0xC6 / 255, green: 0xF0 / 255, blue: 0x6A / 255, alpha: 1)
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
    static var largeTitle: Font { DMSans.font(28, .semibold) }
    static let largeTitleTracking: CGFloat = -0.5
    /// Chat title.
    static var display: Font { DMSans.font(22, .semibold) }
    /// Video title on its page.
    static var videoTitle: Font { DMSans.font(19, .semibold) }
    /// Section headers.
    static var title: Font { DMSans.font(17, .semibold) }
    static var cardTitle: Font { DMSans.font(14, .semibold) }
    static var heading: Font { DMSans.font(15, .semibold) }
    static var rowTitle: Font { DMSans.font(13.5, .semibold) }
    static var body: Font { DMSans.font(13.5) }
    /// Buttons and statuses.
    static var button: Font { DMSans.font(13, .semibold) }
    /// Section labels, tile labels.
    static var label: Font { DMSans.font(12, .semibold) }
    /// Meta lines, empty states, help text.
    static var meta: Font { DMSans.font(12) }
    /// Transcript text.
    static var reading: Font { DMSans.font(15) }
    static var readingStrong: Font { DMSans.font(15, .semibold) }
    static let readingLineSpacing: CGFloat = 9
    /// Chat answers.
    static var chat: Font { DMSans.font(14.5) }
    static var chatStrong: Font { DMSans.font(14.5, .semibold) }
    static let chatLineSpacing: CGFloat = 7
    /// Durations, counts, shortcuts.
    static let mono = Font.system(size: 12, design: .monospaced).monospacedDigit()
    /// Timecode chips and keycaps inside buttons.
    static let chip = Font.system(size: 11.5, weight: .semibold, design: .monospaced).monospacedDigit()
    /// Commands and prompts being edited.
    static let code = Font.system(size: 12, design: .monospaced)
    /// Symbols. Sizes follow where the symbol sits, not the text beside it.
    static let iconHero = Font.system(size: 20, weight: .semibold)
    static let iconTool = Font.system(size: 18)
    static let iconLead = Font.system(size: 16)
    static let iconMark = Font.system(size: 16, weight: .semibold)
    static let iconButton = Font.system(size: 15, weight: .semibold)
    static let iconAction = Font.system(size: 14, weight: .semibold)
    static let icon = Font.system(size: 13, weight: .semibold)
    static let iconBadge = Font.system(size: 12, weight: .bold)
    static let iconSmall = Font.system(size: 10, weight: .bold)
    static let iconMicro = Font.system(size: 9, weight: .bold)
    static let iconSend = Font.system(size: 13, weight: .bold)

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
    static let chatWidth: CGFloat = 640
    static let drawerWidth: CGFloat = 392
}

enum Radius {
    /// Floating layers: menu panel, rack, floating AI window.
    static let ring: CGFloat = 26
    /// The content surface and settings cards.
    static let cell: CGFloat = 18
    /// Chat cards and rack cards.
    static let card: CGFloat = 14
    /// Large thumbnails.
    static let thumb: CGFloat = 12
    /// Row thumbnails.
    static let thumbSmall: CGFloat = 7
    /// Buttons, rows and fields.
    static let row: CGFloat = 10
    static let chip: CGFloat = 6
    /// Chat message bubbles.
    static let bubble: CGFloat = 16
    /// The chat composer.
    static let composer: CGFloat = 26
}

/// Fixed geometry of the menu bar panel, so its height is known before SwiftUI lays it out and the
/// window can grow downward in one step.
enum PanelMetrics {
    static let width: CGFloat = 340
    static let ring: CGFloat = 6
    static let gap: CGFloat = 6
    static let cellPadding: CGFloat = 10
    static let headerHeight: CGFloat = 18
    static let headerGap: CGFloat = 8
    /// A video row: the 32 pt thumbnail plus 4 pt above and below.
    static let rowHeight: CGFloat = 40
    static let visibleRows = 4
    static let emptyHeight: CGFloat = 36
    static let actionsHeight: CGFloat = 50
    static let menuRowHeight: CGFloat = 30
    /// Padding around the menu rows.
    static let menuPadding: CGFloat = 2
    /// A divider with its margins.
    static let ruleHeight: CGFloat = 9
    static let buttonHeight: CGFloat = 40

    static func listHeight(rows: Int) -> CGFloat {
        rows == 0 ? emptyHeight : CGFloat(min(rows, visibleRows)) * rowHeight
    }

    static func sessionHeight(rows: Int) -> CGFloat {
        cellPadding * 2 + headerHeight + headerGap + listHeight(rows: rows)
    }

    /// Menu rows: front tab, paste, export, the optional "earlier today", then the divider and two more.
    static func menuHeight(earlier: Bool) -> CGFloat {
        menuPadding * 2 + CGFloat(earlier ? 6 : 5) * menuRowHeight + ruleHeight
    }

    static func height(rows: Int, earlier: Bool) -> CGFloat {
        ring * 2 + sessionHeight(rows: rows) + gap + actionsHeight + gap + menuHeight(earlier: earlier)
    }
}
