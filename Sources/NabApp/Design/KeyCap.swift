import AppKit
import NabCore
import SwiftUI

/// One key of a shortcut: a rounded square lit a little from above, with a 1 pt edge under it and the symbol in
/// the middle. No texture, no stacked shadows, no tilt.
struct KeyCap: View {
    enum Size {
        case small, medium

        var height: CGFloat { self == .small ? 18 : 26 }
        var radius: CGFloat { self == .small ? 5 : 7 }
        var padding: CGFloat { self == .small ? 4 : 7 }
        var font: Font {
            self == .small ? .system(size: 11, weight: .medium) : .system(size: 14, weight: .medium)
        }
    }

    /// Where the cap sits: on a neutral surface, or on the lime fill of a primary button.
    enum Surface { case neutral, accent }

    let label: String
    var size = Size.small
    var surface = Surface.neutral

    init(_ label: String, size: Size = .small, surface: Surface = .neutral) {
        self.label = label
        self.size = size
        self.surface = surface
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.radius, style: .continuous)
        Text(label)
            .font(size.font)
            .foregroundStyle(surface == .accent ? Palette.onAccent.opacity(0.78) : Palette.ink)
            .padding(.horizontal, size.padding)
            .frame(minWidth: size.height, minHeight: size.height)
            .background(
                shape.fill(
                    surface == .accent ? AnyShapeStyle(Palette.keyCapOnAccent) : AnyShapeStyle(Palette.keyCapFill))
            )
            .overlay(
                shape.strokeBorder(Palette.keyCapLight, lineWidth: 1).mask(alignment: .top) {
                    Rectangle().frame(height: size.height / 2)
                }
            )
            .background(alignment: .bottom) {
                shape.fill(surface == .accent ? Palette.keyCapOnAccentEdge : Palette.keyCapEdge).offset(y: 1)
            }
            .padding(.bottom, 1)
            .accessibilityHidden(true)
    }
}

/// A shortcut as key caps, in the keyboard layout in use. Nothing when there is no combination.
struct KeyCaps: View {
    let combo: KeyCombo?
    var size = KeyCap.Size.small
    var surface = KeyCap.Surface.neutral

    init(_ combo: KeyCombo?, size: KeyCap.Size = .small, surface: KeyCap.Surface = .neutral) {
        self.combo = combo
        self.size = size
        self.surface = surface
    }

    var body: some View {
        if let combo {
            let parts = combo.parts(character: KeyLayout.character(for: combo.keyCode))
            HStack(spacing: size == .small ? 3 : 4) {
                ForEach(Array(parts.enumerated()), id: \.offset) { KeyCap($0.element, size: size, surface: surface) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(parts.joined(separator: " "))
        }
    }
}

extension Palette {
    /// Key cap face, its top light, and the 1 pt edge below it; the same on the lime fill of a primary button.
    static let keyCapFill = keyCapColor(dark: (0xFFFFFF, 0.10), light: (0xFFFFFF, 1.0))
    static let keyCapLight = keyCapColor(dark: (0xFFFFFF, 0.16), light: (0xFFFFFF, 1.0))
    static let keyCapEdge = keyCapColor(dark: (0x000000, 0.45), light: (0x14181E, 0.20))
    static let keyCapOnAccent = Color(nsColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28))
    static let keyCapOnAccentEdge = Color(nsColor: NSColor(srgbRed: 0.06, green: 0.07, blue: 0.08, alpha: 0.28))

    private static func keyCapColor(dark: (UInt32, CGFloat), light: (UInt32, CGFloat)) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                let (hex, alpha) = isDark ? dark : light
                return NSColor(
                    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
            })
    }
}
