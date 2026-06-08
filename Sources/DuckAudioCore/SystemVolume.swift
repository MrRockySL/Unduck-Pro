import CoreAudio
import Foundation

/// A selectable hardware output (built-in speakers, AirPods, external DAC, …).
public struct AudioOutputDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public init(id: AudioDeviceID, name: String) { self.id = id; self.name = name }
}

/// Reads/sets the real macOS system output volume + device name — for the
/// master "System Output" row at the top of the mixer.
public enum SystemVolume {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    private static func addr(_ selector: AudioObjectPropertySelector,
                             _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func defaultOutputDevice() -> AudioDeviceID {
        var dev = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectGetPropertyData(system, &a, 0, nil, &size, &dev)
        return dev
    }

    public static func deviceName() -> String {
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return "Output" }
        return name(of: dev) ?? "Output"
    }

    private static func name(of dev: AudioDeviceID) -> String? {
        var a = addr(kAudioObjectPropertyName)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var name: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &name) == noErr, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    /// Does this device have at least one output channel?
    private static func hasOutput(_ dev: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                    alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(dev, &a, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func transportType(_ dev: AudioDeviceID) -> UInt32 {
        var a = addr(kAudioDevicePropertyTransportType)
        var t: UInt32 = 0; var size = UInt32(4)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &t)
        return t
    }

    private static func isHidden(_ dev: AudioDeviceID) -> Bool {
        var a = addr(kAudioDevicePropertyIsHidden)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var h: UInt32 = 0; var size = UInt32(4)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &size, &h)
        return h != 0
    }

    /// Real, user-selectable output devices — matches what macOS Sound settings
    /// lists (built-in, AirPods, USB/HDMI…). Hides virtual/aggregate/loopback
    /// drivers (NoMachine, BlackHole, our own private aggregate, etc.).
    public static func outputDevices() -> [AudioOutputDevice] {
        var a = addr(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &a, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &a, 0, nil, &size, &ids) == noErr else { return [] }

        let hiddenTransports: Set<UInt32> = [
            kAudioDeviceTransportTypeVirtual,
            kAudioDeviceTransportTypeAggregate,
            kAudioDeviceTransportTypeAutoAggregate
        ]
        return ids.compactMap { dev in
            guard hasOutput(dev), !isHidden(dev),
                  !hiddenTransports.contains(transportType(dev)),
                  let n = name(of: dev) else { return nil }
            return AudioOutputDevice(id: dev, name: n)
        }
    }

    /// Switch the macOS default output device (so audio actually moves there).
    public static func setDefaultOutputDevice(_ id: AudioDeviceID) {
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        AudioObjectSetPropertyData(system, &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    /// Current system output volume (0…1), or nil if the device has no volume.
    public static func volume() -> Float? {
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return nil }

        var main = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(dev, &main) {
            var v: Float32 = 0; var z = UInt32(4)
            if AudioObjectGetPropertyData(dev, &main, 0, nil, &z, &v) == noErr { return v }
        }
        // Per-channel average (devices that expose L/R but no main).
        var sum: Float = 0; var count = 0
        for ch in [UInt32(1), UInt32(2)] {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)
            if AudioObjectHasProperty(dev, &a) {
                var v: Float32 = 0; var z = UInt32(4)
                if AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &v) == noErr { sum += v; count += 1 }
            }
        }
        return count > 0 ? sum / Float(count) : nil
    }

    public static func setVolume(_ value: Float) {
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return }
        let v = max(0, min(1, value))

        var main = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(dev, &main),
           AudioObjectIsPropertySettable(dev, &main, &settable) == noErr, settable.boolValue {
            var val = v
            AudioObjectSetPropertyData(dev, &main, 0, nil, 4, &val)
            return
        }
        for ch in [UInt32(1), UInt32(2)] {
            var a = addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)
            var s: DarwinBoolean = false
            if AudioObjectHasProperty(dev, &a),
               AudioObjectIsPropertySettable(dev, &a, &s) == noErr, s.boolValue {
                var val = v
                AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &val)
            }
        }
    }

    public static func isMuted() -> Bool {
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return false }
        var a = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        guard AudioObjectHasProperty(dev, &a) else { return false }
        var m: UInt32 = 0; var z = UInt32(4)
        AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &m)
        return m != 0
    }

    public static func setMuted(_ muted: Bool) {
        let dev = defaultOutputDevice()
        guard dev != kAudioObjectUnknown else { return }
        var a = addr(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(dev, &a),
              AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue else { return }
        var m: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &m)
    }
}
