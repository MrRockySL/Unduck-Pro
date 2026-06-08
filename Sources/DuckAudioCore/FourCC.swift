import CoreAudio

public enum FourCC {
    public static func make(_ value: String) -> AudioObjectPropertySelector {
        precondition(value.utf8.count == 4, "FourCC values must be exactly 4 ASCII bytes")

        var result: UInt32 = 0
        for byte in value.utf8 {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    public static func string(_ value: AudioObjectPropertySelector) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
