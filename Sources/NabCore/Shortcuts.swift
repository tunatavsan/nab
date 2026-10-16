import Foundation

/// What a global shortcut can do.
public enum ShortcutAction: String, Codable, CaseIterable, Sendable {
    case nab, copySession, summarize, newSession

    /// The row title in Settings.
    public var title: String {
        switch self {
        case .nab: "Nab the YouTube tab in front"
        case .copySession: "Copy the whole session"
        case .summarize: "Ask AI about the session"
        case .newSession: "Start a new session"
        }
    }
}

/// One key with its modifiers. `keyCode` is a virtual key code (`kVK_*`, the key's place on the keyboard) and
/// `modifiers` a Carbon mask, which is what `RegisterEventHotKey` takes.
public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    // Carbon masks (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public static let command: UInt32 = 0x100
    public static let shift: UInt32 = 0x200
    public static let option: UInt32 = 0x800
    public static let control: UInt32 = 0x1000

    /// The modifier symbols in the order macOS shows them: ⌃⌥⇧⌘.
    public static let modifierOrder: [(mask: UInt32, symbol: String)] = [
        (control, "⌃"), (option, "⌥"), (shift, "⇧"), (command, "⌘"),
    ]

    /// Carbon mask from `NSEvent.ModifierFlags.rawValue`; caps lock, fn and the rest are dropped.
    public static func carbonModifiers(eventFlags raw: UInt) -> UInt32 {
        var mask: UInt32 = 0
        if raw & (1 << 18) != 0 { mask |= control }
        if raw & (1 << 19) != 0 { mask |= option }
        if raw & (1 << 17) != 0 { mask |= shift }
        if raw & (1 << 20) != 0 { mask |= command }
        return mask
    }

    /// The modifier symbols of this combination, ⌃⌥⇧⌘.
    public var modifierSymbols: [String] {
        Self.modifierOrder.filter { modifiers & $0.mask != 0 }.map(\.symbol)
    }

    /// Symbols for keys that do not type a character, by virtual key code.
    public static let specialKeys: [UInt32: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌅", 117: "⌦",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9",
        109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17",
        79: "F18", 80: "F19", 90: "F20",
    ]

    /// The key cap labels, modifiers first. `character` names the key when it types one, in the current keyboard
    /// layout (the caller asks the system); special keys come from the fixed table.
    public func parts(character: String) -> [String] {
        modifierSymbols + [Self.specialKeys[keyCode] ?? character]
    }

    /// "⌃⌥N".
    public func text(character: String) -> String { parts(character: character).joined() }

    /// Virtual key codes of the ANSI letters and digits, which ⌘ alone must not take.
    static let letterAndDigitCodes: Set<UInt32> = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 13, 14, 15, 16, 17, 31, 32, 34, 35, 37, 38, 40, 45, 46,
        18, 19, 20, 21, 22, 23, 25, 26, 28, 29,
    ]
}

/// Why a combination cannot be assigned.
public enum ShortcutValidation: Equatable, Sendable {
    case valid
    /// No ⌃, ⌥ or ⌘ (⇧ alone does not count).
    case needsModifier
    /// ⌘ with a letter or a digit belongs to the app in front.
    case takenByApps
    case conflict(ShortcutAction)

    public var message: String? {
        switch self {
        case .valid: nil
        case .needsModifier: "Include ⌃, ⌥ or ⌘ so it does not clash with typing."
        case .takenByApps: "⌘ with a letter or digit belongs to the app in front. Add ⌃ or ⌥."
        case .conflict(let other): "Already used for “\(other.title)”."
        }
    }
}

/// The shortcut for each action. An action with no entry has its default; an entry of `nil` means no shortcut.
public struct ShortcutMap: Codable, Equatable, Sendable {
    public static let defaults: [ShortcutAction: KeyCombo] = {
        let mask = KeyCombo.control | KeyCombo.option
        return [
            .nab: KeyCombo(keyCode: 45, modifiers: mask),  // N
            .copySession: KeyCombo(keyCode: 0, modifiers: mask),  // A
            .summarize: KeyCombo(keyCode: 1, modifiers: mask),  // S
            .newSession: KeyCombo(keyCode: 7, modifiers: mask),  // X
        ]
    }()

    private var stored: [String: KeyCombo?]

    public init() { stored = [:] }

    public func combo(for action: ShortcutAction) -> KeyCombo? {
        if let entry = stored[action.rawValue] { return entry }
        return Self.defaults[action]
    }

    /// `nil` clears the shortcut; it does not bring the default back (see `reset`).
    public mutating func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        stored[action.rawValue] = .some(combo)
    }

    public mutating func reset(_ action: ShortcutAction) { stored[action.rawValue] = nil }

    public mutating func resetAll() { stored = [:] }

    public var isDefault: Bool { ShortcutAction.allCases.allSatisfy { combo(for: $0) == Self.defaults[$0] } }

    /// Whether `combo` may be assigned to `action`.
    public func validate(_ combo: KeyCombo, for action: ShortcutAction) -> ShortcutValidation {
        let strong = KeyCombo.control | KeyCombo.option | KeyCombo.command
        guard combo.modifiers & strong != 0 else { return .needsModifier }
        if combo.modifiers & strong == KeyCombo.command, KeyCombo.letterAndDigitCodes.contains(combo.keyCode) {
            return .takenByApps
        }
        if let other = ShortcutAction.allCases.first(where: { $0 != action && self.combo(for: $0) == combo }) {
            return .conflict(other)
        }
        return .valid
    }

    /// The stored JSON; `data` that is missing or unreadable gives the defaults.
    public static func decode(_ data: Data?) -> ShortcutMap {
        guard let data, let map = try? JSONDecoder().decode(ShortcutMap.self, from: data) else { return ShortcutMap() }
        return map
    }

    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
}
