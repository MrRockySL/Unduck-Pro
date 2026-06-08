import CoreAudio
import Foundation

public struct DuckPropertySnapshot: Equatable, Sendable {
    public let deviceID: AudioObjectID
    public let scopeName: String
    public let scope: AudioObjectPropertyScope
    public let hasProperty: Bool
    public let rawBytes: [UInt8]

    public init(
        deviceID: AudioObjectID,
        scopeName: String,
        scope: AudioObjectPropertyScope,
        hasProperty: Bool,
        rawBytes: [UInt8]
    ) {
        self.deviceID = deviceID
        self.scopeName = scopeName
        self.scope = scope
        self.hasProperty = hasProperty
        self.rawBytes = rawBytes
    }

    public var isAllZero: Bool {
        rawBytes.allSatisfy { $0 == 0 }
    }

    public var hex: String {
        rawBytes
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }

    public var float32Values: [Float32] {
        rawBytes.withUnsafeBytes { rawBuffer in
            let count = rawBytes.count / MemoryLayout<Float32>.stride
            guard count > 0 else {
                return []
            }

            return (0..<count).map { index in
                let offset = index * MemoryLayout<Float32>.stride
                return rawBuffer.loadUnaligned(fromByteOffset: offset, as: Float32.self)
            }
        }
    }
}

public enum DuckPropertyReader {
    public static let selector = FourCC.make("duck")

    public static func readAllScopes(deviceID: AudioObjectID) throws -> [DuckPropertySnapshot] {
        try [
            ("global", kAudioObjectPropertyScopeGlobal),
            ("output", kAudioDevicePropertyScopeOutput),
            ("input", kAudioDevicePropertyScopeInput)
        ].map { scopeName, scope in
            try read(deviceID: deviceID, scopeName: scopeName, scope: scope)
        }
    }

    public static func read(
        deviceID: AudioObjectID,
        scopeName: String = "global",
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> DuckPropertySnapshot {
        let propertyAddress = CoreAudioProperty.address(selector, scope: scope)
        let hasDuckProperty = CoreAudioProperty.hasProperty(
            objectID: deviceID,
            address: propertyAddress
        )

        guard hasDuckProperty else {
            return DuckPropertySnapshot(
                deviceID: deviceID,
                scopeName: scopeName,
                scope: scope,
                hasProperty: false,
                rawBytes: []
            )
        }

        let bytes = try CoreAudioProperty.readData(
            objectID: deviceID,
            address: propertyAddress
        )

        return DuckPropertySnapshot(
            deviceID: deviceID,
            scopeName: scopeName,
            scope: scope,
            hasProperty: true,
            rawBytes: bytes
        )
    }
}
