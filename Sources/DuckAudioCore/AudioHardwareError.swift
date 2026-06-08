import CoreAudio
import Foundation

public struct AudioHardwareError: Error, CustomStringConvertible, Equatable, Sendable {
    public let operation: String
    public let status: OSStatus

    public init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }

    public var description: String {
        "\(operation) failed with OSStatus \(status) (\(Self.fourCC(status)))"
    }

    public static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw AudioHardwareError(operation: operation, status: status)
        }
    }

    public static func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status)
        let scalars = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]

        guard scalars.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
            return "0x" + String(value, radix: 16, uppercase: true)
        }

        return String(bytes: scalars, encoding: .ascii) ?? "0x" + String(value, radix: 16, uppercase: true)
    }
}
