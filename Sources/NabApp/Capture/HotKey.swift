import Carbon.HIToolbox

struct HotKeyError: LocalizedError {
    let call: String
    let status: OSStatus
    var errorDescription: String? { "\(call) failed (OSStatus \(status))" }
}

/// A system-wide shortcut through Carbon's hot key API: it needs no Accessibility permission and
/// fires even while another app is in front.
@MainActor
final class HotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?

    /// Throws if the system refuses the handler or the key (for example, another app owns it).
    /// `keyCode` is a `kVK_` constant, `modifiers` Carbon flags such as `controlKey | optionKey`.
    init(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping () -> Void) throws {
        try Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E61_6221), id: id)  // 'Nab!'
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetEventDispatcherTarget(), 0, &reference)
        guard status == noErr else { throw HotKeyError(call: "RegisterEventHotKey", status: status) }
        Self.actions[id] = action
    }

    private static func installHandler() throws {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let id = hotKeyID.id
                // Carbon delivers hot keys on the main run loop.
                MainActor.assumeIsolated { HotKey.actions[id]?() }
                return noErr
            }, 1, &spec, nil, &handler)
        guard status == noErr else { throw HotKeyError(call: "InstallEventHandler", status: status) }
    }
}
