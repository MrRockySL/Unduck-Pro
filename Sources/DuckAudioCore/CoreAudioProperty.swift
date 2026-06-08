import CoreAudio
import Foundation

public enum CoreAudioProperty {
    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: element
        )
    }

    public static func hasProperty(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) -> Bool {
        var mutableAddress = address
        return AudioObjectHasProperty(objectID, &mutableAddress)
    }

    public static func dataSize(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        qualifier: UnsafeRawPointer? = nil,
        qualifierSize: UInt32 = 0
    ) throws -> UInt32 {
        var mutableAddress = address
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            objectID,
            &mutableAddress,
            qualifierSize,
            qualifier,
            &size
        )
        try AudioHardwareError.check(status, operation: "AudioObjectGetPropertyDataSize(\(FourCC.string(address.mSelector)))")
        return size
    }

    public static func readUInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> UInt32 {
        var value: UInt32 = 0
        try readIntoPointer(objectID: objectID, address: address, value: &value)
        return value
    }

    public static func readInt32(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Int32 {
        var value: Int32 = 0
        try readIntoPointer(objectID: objectID, address: address, value: &value)
        return value
    }

    public static func readFloat64(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> Float64 {
        var value: Float64 = 0
        try readIntoPointer(objectID: objectID, address: address, value: &value)
        return value
    }

    public static func readAudioObjectID(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> AudioObjectID {
        var value = kAudioObjectUnknown
        try readIntoPointer(objectID: objectID, address: address, value: &value)
        return value
    }

    public static func readAudioObjectIDs(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [AudioObjectID] {
        let size = try dataSize(objectID: objectID, address: address)
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        guard count > 0 else {
            return []
        }

        var mutableAddress = address
        var mutableSize = size
        var values = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &mutableSize,
                buffer.baseAddress!
            )
        }
        try AudioHardwareError.check(status, operation: "AudioObjectGetPropertyData(\(FourCC.string(address.mSelector)))")
        return values
    }

    public static func readData(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> [UInt8] {
        let size = try dataSize(objectID: objectID, address: address)
        guard size > 0 else {
            return []
        }

        var mutableAddress = address
        var mutableSize = size
        var bytes = [UInt8](repeating: 0, count: Int(size))
        let status = bytes.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &mutableSize,
                buffer.baseAddress!
            )
        }
        try AudioHardwareError.check(status, operation: "AudioObjectGetPropertyData(\(FourCC.string(address.mSelector)))")
        return bytes
    }

    public static func readCFString(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress
    ) throws -> String? {
        var mutableAddress = address
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        try AudioHardwareError.check(status, operation: "AudioObjectGetPropertyData(\(FourCC.string(address.mSelector)))")
        return value as String?
    }

    public static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        var mutablePID = pid
        var objectID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)

        let status = withUnsafePointer(to: &mutablePID) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &objectID
            )
        }
        try AudioHardwareError.check(status, operation: "AudioObjectGetPropertyData(id2p)")
        return objectID
    }

    private static func readIntoPointer<T>(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        value: inout T
    ) throws {
        var mutableAddress = address
        var dataSize = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                objectID,
                &mutableAddress,
                0,
                nil,
                &dataSize,
                pointer
            )
        }
        try AudioHardwareError.check(status, operation: "AudioObjectGetPropertyData(\(FourCC.string(address.mSelector)))")
    }
}
