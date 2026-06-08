import CoreAudio
import Foundation

public struct OutputDeviceInfo: Equatable, Sendable {
    public let id: AudioObjectID
    public let name: String?
    public let uid: String?
    public let nominalSampleRate: Float64?

    public init(id: AudioObjectID, name: String?, uid: String?, nominalSampleRate: Float64?) {
        self.id = id
        self.name = name
        self.uid = uid
        self.nominalSampleRate = nominalSampleRate
    }
}

public enum AudioDeviceProbe {
    public static func defaultOutputDeviceID() throws -> AudioObjectID {
        try CoreAudioProperty.readAudioObjectID(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyDefaultOutputDevice)
        )
    }

    public static func defaultOutputDeviceInfo() throws -> OutputDeviceInfo {
        let deviceID = try defaultOutputDeviceID()
        return OutputDeviceInfo(
            id: deviceID,
            name: try? CoreAudioProperty.readCFString(
                objectID: deviceID,
                address: CoreAudioProperty.address(kAudioObjectPropertyName)
            ),
            uid: try? CoreAudioProperty.readCFString(
                objectID: deviceID,
                address: CoreAudioProperty.address(kAudioDevicePropertyDeviceUID)
            ),
            nominalSampleRate: try? CoreAudioProperty.readFloat64(
                objectID: deviceID,
                address: CoreAudioProperty.address(kAudioDevicePropertyNominalSampleRate)
            )
        )
    }
}
