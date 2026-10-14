import AppKit
import Carbon

private let dockHotKeySignature: OSType = 0x5352_446B  // 'SRDk'

/// A global keyboard shortcut through Carbon's `RegisterEventHotKey`: it needs no Accessibility or Input Monitoring
/// permission (the system only tells the app about its own combination). The dock registers ⌃⌥K, ⌃⌥D and ⌃⌥M (or what
/// Settings recorded instead, DockShortcutCenter); the voice work registers the talk shortcut with its own handler on
/// the same event target, so this handler answers only hot keys carrying its own signature and passes every other one
/// on (`eventNotHandledErr`). A key that wants its release too (⌃⌥N: a voice note records while it is held) gets
/// `kEventHotKeyReleased` as well, also without any permission.
@MainActor
final class DockHotKey {
    private static var actions: [UInt32: () -> Void] = [:]
    private static var releases: [UInt32: () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private static var nextId: UInt32 = 1
    /// What Carbon answered the last registration (`eventHotKeyExistsErr`: another app has the combination).
    private(set) static var lastStatus: OSStatus = noErr

    private var ref: EventHotKeyRef?
    private let id: UInt32

    /// nil when the combination is taken by another app (or Carbon refused it); the reason is logged unless `quiet`
    /// (keys held only for a moment, like the dock's size keys while the pointer is on it). `exclusive`: Carbon refuses
    /// it while another app holds it exclusively too, and refuses such an app while SamRabbit holds it (a registration
    /// without exclusivity, ours or another app's, is never refused: the combination is shared and nobody is told).
    init?(keyCode: Int, modifiers: Int, name: String, quiet: Bool = false, exclusive: Bool = false, action: @escaping () -> Void,
          release: (() -> Void)? = nil) {
        Self.installHandler()
        id = Self.nextId
        Self.nextId += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: dockHotKeySignature, id: id),
                                         GetApplicationEventTarget(), exclusive ? OptionBits(kEventHotKeyExclusive) : 0, &ref)
        Self.lastStatus = status
        guard status == noErr, let ref else {
            if !quiet {
                Log.write(status == eventHotKeyExistsErr ? "shortcut \(name) is taken by another app" : "shortcut \(name) not registered (\(status))")
            }
            return nil
        }
        self.ref = ref
        Self.actions[id] = action
        Self.releases[id] = release
        if !quiet { Log.write("shortcut \(name) registered") }
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
        Self.releases[id] = nil
    }

    private static func installHandler() {
        guard handler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard status == noErr, hotKey.signature == dockHotKeySignature else { return OSStatus(eventNotHandledErr) }
            let id = hotKey.id
            let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if released { DockHotKey.releases[id]?() } else { DockHotKey.actions[id]?() }
                }
            }
            return noErr
        }, specs.count, &specs, nil, &handler)
    }
}
