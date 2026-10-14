import AppKit
import Carbon

private let dockHotKeySignature: OSType = 0x5352_446B  // 'SRDk'

/// A global keyboard shortcut through Carbon's `RegisterEventHotKey`: it needs no Accessibility or Input Monitoring
/// permission (the system only tells the app about its own combination). The dock registers ⌃⌥K, ⌃⌥D and ⌃⌥M (or what
/// Settings recorded instead, DockShortcutCenter); the voice work registers the talk shortcut with its own handler on
/// the same event target, so this handler answers only hot keys carrying its own signature and passes every other one
/// on (`eventNotHandledErr`).
@MainActor
final class DockHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private static var nextId: UInt32 = 1
    /// What Carbon answered the last registration (`eventHotKeyExistsErr`: another app has the combination).
    private(set) static var lastStatus: OSStatus = noErr

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// nil when the combination is taken by another app (or Carbon refused it); the reason is logged unless `quiet`
    /// (keys held only for a moment, like the dock's size keys while the pointer is on it).
    init?(keyCode: Int, modifiers: Int, name: String, quiet: Bool = false, action: @escaping () -> Void) {
        Self.installHandler()
        id = Self.nextId
        Self.nextId += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: dockHotKeySignature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        Self.lastStatus = status
        guard status == noErr, let ref else {
            if !quiet {
                Log.write(status == eventHotKeyExistsErr ? "shortcut \(name) is taken by another app" : "shortcut \(name) not registered (\(status))")
            }
            return nil
        }
        self.ref = ref
        Self.actions[id] = action
        if !quiet { Log.write("shortcut \(name) registered") }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == dockHotKeySignature else { return OSStatus(eventNotHandledErr) }
            let id = hotKey.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { DockHotKey.actions[id]?() }
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}
