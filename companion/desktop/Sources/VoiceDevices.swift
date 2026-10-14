import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// The Mac's audio inputs through CoreAudio, for the "Hey Rabbit" listener's choice of microphone
/// (`WakeMicrophoneChoice`). Reading them opens no microphone and asks for no permission.
enum AudioInputs {
    /// Every audio device, with whether it has an input and how it is connected.
    static func devices() -> [WakeMicrophoneChoice.Device] {
        var address = Self.address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.map { id in
            WakeMicrophoneChoice.Device(id: id, name: name(of: id) ?? "A microphone", transport: transport(of: id),
                                        hasInput: hasInput(id))
        }
    }

    /// The system's default input device, or nil when there is none.
    static func defaultInput() -> UInt32? {
        var address = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Makes `input` (an engine's input node, before the engine starts) record from `device`.
    static func use(_ device: UInt32, for input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw VoiceAudio.StartFailure.engine("no input unit") }
        var id = AudioDeviceID(device)
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw VoiceAudio.StartFailure.engine("device \(status)") }
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = Self.address(kAudioObjectPropertyName)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func transport(of id: AudioObjectID) -> WakeMicrophoneChoice.Transport {
        var address = Self.address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return .other }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeContinuityCaptureWired, kAudioDeviceTransportTypeContinuityCaptureWireless:
            return .continuity
        default: return .other
        }
    }

    private static func hasInput(_ id: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }
}

/// Calls back on the main actor when the default input or the set of audio devices changes (AirPods connected or
/// chosen as the input, a USB microphone plugged in), until `invalidate()`.
@MainActor
final class AudioInputWatcher {
    private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    init(changed: @escaping @MainActor () -> Void) {
        for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { changed() }
            }
            guard AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr
            else { continue }
            listeners.append((address, block))
        }
    }

    func invalidate() {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
        listeners = []
    }
}
