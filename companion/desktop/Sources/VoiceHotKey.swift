import Carbon.HIToolbox
import Foundation

/// A global keyboard shortcut (⌃⌥Space talks to SamRabbit from any app) through Carbon's `RegisterEventHotKey`:
/// the system delivers just that key combination to SamRabbit, so no Accessibility or Input Monitoring permission is
/// involved and no other keystroke is ever seen.
///
/// Several shortcuts share the application's event target (the dock registers ⌃⌥K the same way): each handler only
/// takes its own hot key (signature and id) and passes the others on (`eventNotHandledErr`).
@MainActor
final class VoiceHotKey {
    /// "SRvc"
    static let signature: OSType = 0x5352_7663
    static let shortcutDescription = "⌃⌥Space"

    private let id: UInt32
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var lastPress = Date.distantPast

    /// Registers `keyCode` + `modifiers` (Carbon values); nil when the system refused it (another app has it).
    init?(keyCode: UInt32 = UInt32(kVK_Space), modifiers: UInt32 = UInt32(controlKey | optionKey), id: UInt32 = 1,
          action: @escaping @MainActor () -> Void) {
        self.id = id
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let me = Unmanaged<VoiceHotKey>.fromOpaque(context).takeUnretainedValue()
            guard status == noErr, pressed.signature == VoiceHotKey.signature, pressed.id == me.id else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated { me.pressed() }
            return noErr
        }, 1, &spec, context, &handler)
        guard installed == noErr else { return nil }
        let hotKeyId = EventHotKeyID(signature: Self.signature, id: id)
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyId, GetApplicationEventTarget(), 0, &hotKey)
        guard registered == noErr else {
            if let handler { RemoveEventHandler(handler) }
            Log.write("voice: the shortcut \(Self.shortcutDescription) is taken (\(registered))")
            return nil
        }
        Log.write("voice: shortcut \(Self.shortcutDescription) registered")
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private func pressed() {
        // A held key or a double press within a moment is one press.
        guard Date().timeIntervalSince(lastPress) > 0.35 else { return }
        lastPress = Date()
        action()
    }
}
