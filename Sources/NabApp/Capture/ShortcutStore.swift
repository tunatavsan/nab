import AppKit
import Carbon.HIToolbox
import NabCore

/// The global shortcuts: what the user chose (kept in UserDefaults under `shortcuts`), what the system accepted,
/// and the Carbon registrations. Views read `combo(for:)`, so a change shows everywhere at once.
@MainActor @Observable
final class ShortcutStore {
    static let shared = ShortcutStore()
    static let defaultsKey = "shortcuts"

    private(set) var map: ShortcutMap
    /// Actions whose combination the system refused when it was registered ("In use by another app").
    private(set) var unavailable: Set<ShortcutAction> = []
    /// The action whose last attempted combination the system refused; the old one stayed.
    private(set) var refused: ShortcutAction?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var handlers: [ShortcutAction: () -> Void] = [:]
    @ObservationIgnored private var hotKeys: [ShortcutAction: HotKey] = [:]
    @ObservationIgnored private var paused = false
    /// Called after every registration pass, so the capture center can follow the Nab shortcut's availability.
    @ObservationIgnored var onRegistered: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        map = ShortcutMap.decode(defaults.data(forKey: Self.defaultsKey))
    }

    func combo(for action: ShortcutAction) -> KeyCombo? { map.combo(for: action) }

    /// "⌃⌥N", or nil when the action has no shortcut.
    func text(for action: ShortcutAction) -> String? {
        combo(for: action).map { $0.text(character: KeyLayout.character(for: $0.keyCode)) }
    }

    /// Whether the interface should advertise the shortcut: set, and accepted by the system.
    func isActive(_ action: ShortcutAction) -> Bool {
        combo(for: action) != nil && !unavailable.contains(action)
    }

    func validate(_ combo: KeyCombo, for action: ShortcutAction) -> ShortcutValidation {
        map.validate(combo, for: action)
    }

    /// Hands over what each shortcut does and registers them.
    func install(handlers: [ShortcutAction: () -> Void]) {
        self.handlers = handlers
        register()
    }

    /// Assigns `combo` (or clears with nil). If the system refuses it the old combination stays and `refused` names
    /// the action. Returns whether the change took.
    @discardableResult
    func assign(_ combo: KeyCombo?, to action: ShortcutAction) -> Bool {
        if let combo, map.validate(combo, for: action) != .valid { return false }
        let before = map
        refused = nil
        map.set(combo, for: action)
        register()
        if combo != nil, unavailable.contains(action) {
            map = before
            refused = action
            register()
            return false
        }
        persist()
        return true
    }

    func restoreDefaults() {
        refused = nil
        map.resetAll()
        register()
        persist()
    }

    /// Recording needs the keys to reach the app, so the global ones step aside meanwhile.
    func pause() {
        paused = true
        unregisterAll()
    }

    func resume() {
        paused = false
        register()
    }

    private func persist() {
        if map.isDefault {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(map.encoded(), forKey: Self.defaultsKey)
        }
    }

    private func unregisterAll() {
        for hotKey in hotKeys.values { hotKey.unregister() }
        hotKeys = [:]
    }

    /// Registers every shortcut afresh and notes which ones the system refused.
    private func register() {
        unregisterAll()
        unavailable = []
        guard !paused else { return }
        for (index, action) in ShortcutAction.allCases.enumerated() {
            guard let combo = map.combo(for: action), let handler = handlers[action] else { continue }
            do {
                hotKeys[action] = try HotKey(
                    keyCode: Int(combo.keyCode), modifiers: Int(combo.modifiers), id: UInt32(index + 1), action: handler
                )
            } catch {
                unavailable.insert(action)
                NSLog("Nab: the %@ shortcut is unavailable: %@", action.rawValue, error.localizedDescription)
            }
        }
        onRegistered?()
    }
}

/// Key labels in the keyboard layout in use, so a Turkish layout shows its own letters.
enum KeyLayout {
    static func character(for keyCode: UInt32) -> String {
        if let special = KeyCombo.specialKeys[keyCode] { return special }
        for source in [
            TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
        ] {
            guard let source, let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                continue
            }
            let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            let label = data.withUnsafeBytes { buffer -> String? in
                guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(
                    layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length).uppercased()
            }
            if let label, !label.trimmingCharacters(in: .whitespaces).isEmpty { return label }
        }
        return "Key \(keyCode)"
    }
}
