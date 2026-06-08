import Foundation

public struct AudioLevels: Equatable, Sendable {
    public let peak: Float
    public let rms: Float

    public init(peak: Float, rms: Float) {
        self.peak = peak
        self.rms = rms
    }

    public static let silence = AudioLevels(peak: 0, rms: 0)
}

public enum LevelMeter {
    public static func measure(_ samples: [Float]) -> AudioLevels {
        guard !samples.isEmpty else {
            return .silence
        }

        var peak: Float = 0
        var sumOfSquares: Double = 0

        for sample in samples {
            let cleanSample = sample.isFinite ? sample : 0
            let absolute = abs(cleanSample)
            peak = max(peak, absolute)
            sumOfSquares += Double(cleanSample * cleanSample)
        }

        return AudioLevels(
            peak: peak,
            rms: Float((sumOfSquares / Double(samples.count)).squareRoot())
        )
    }
}
