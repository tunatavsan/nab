import AppKit
import CoreText
import SwiftUI

/// DM Sans (OFL, bundled in Contents/Resources/Fonts) as a variable font: weight and optical size
/// are set per size, so 11 pt captions and 15 pt titles each get the cut drawn for them.
/// Falls back to the system font if the file is missing.
@MainActor
enum DMSans {
    private static let descriptor: CTFontDescriptor? = {
        guard let url = Bundle.main.url(forResource: "DMSans", withExtension: "ttf", subdirectory: "Fonts"),
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]
        else { return nil }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        return descriptors.first
    }()

    private static var cache: [String: Font] = [:]

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let key = "\(size)-\(weight)"
        if let cached = cache[key] { return cached }
        let font: Font
        if let descriptor {
            let axes: [NSNumber: NSNumber] = [
                0x7767_6874: NSNumber(value: axis(weight)),  // wght
                0x6F70_737A: NSNumber(value: Double(min(40, max(9, size)))),  // opsz
            ]
            let sized = CTFontDescriptorCreateCopyWithAttributes(
                descriptor, [kCTFontVariationAttribute as String: axes] as CFDictionary)
            font = Font(CTFontCreateWithFontDescriptor(sized, size, nil))
        } else {
            font = .system(size: size, weight: weight)
        }
        cache[key] = font
        return font
    }

    private static func axis(_ weight: Font.Weight) -> Double {
        switch weight {
        case .ultraLight: 100
        case .thin: 200
        case .light: 300
        case .medium: 500
        case .semibold: 600
        case .bold: 700
        case .heavy: 800
        case .black: 900
        default: 400
        }
    }
}
