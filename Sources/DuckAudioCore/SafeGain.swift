import Foundation

public struct HardLimiter: Equatable, Sendable {
    public let ceiling: Float

    public init(ceiling: Float = 0.90) {
        precondition(ceiling > 0 && ceiling <= 1)
        self.ceiling = ceiling
    }

    public func process(_ sample: Float) -> Float {
        guard sample.isFinite else {
            return 0
        }

        if sample > ceiling {
            return ceiling
        }
        if sample < -ceiling {
            return -ceiling
        }
        return sample
    }

    public func process(_ samples: [Float]) -> [Float] {
        samples.map(process)
    }
}

public struct SafeGainConfig: Equatable, Sendable {
    public let maxGain: Float
    public let maxGainRisePerBuffer: Float
    public let maxGainFallPerBuffer: Float
    public let limiter: HardLimiter

    public init(
        maxGain: Float = 10,
        maxGainStepPerBuffer: Float = 0.25,
        maxGainFallPerBuffer: Float? = nil,
        limiter: HardLimiter = HardLimiter()
    ) {
        precondition(maxGain >= 1)
        precondition(maxGainStepPerBuffer > 0)
        if let maxGainFallPerBuffer {
            precondition(maxGainFallPerBuffer > 0)
        }
        self.maxGain = maxGain
        self.maxGainRisePerBuffer = maxGainStepPerBuffer
        self.maxGainFallPerBuffer = maxGainFallPerBuffer ?? maxGainStepPerBuffer
        self.limiter = limiter
    }
}

public struct SafeGainResult: Equatable, Sendable {
    public let samples: [Float]
    public let appliedGain: Float
    public let inputLevels: AudioLevels
    public let outputLevels: AudioLevels
}

public struct SafeGainAnalysisResult: Equatable, Sendable {
    public let appliedGain: Float
    public let inputLevels: AudioLevels
    public let outputLevels: AudioLevels
    public let sampleCount: Int
    public let limitedSampleCount: Int

    public init(
        appliedGain: Float,
        inputLevels: AudioLevels,
        outputLevels: AudioLevels,
        sampleCount: Int,
        limitedSampleCount: Int
    ) {
        self.appliedGain = appliedGain
        self.inputLevels = inputLevels
        self.outputLevels = outputLevels
        self.sampleCount = sampleCount
        self.limitedSampleCount = limitedSampleCount
    }
}

public struct SafeGainStage: Sendable {
    public let config: SafeGainConfig
    public private(set) var currentGain: Float

    public init(config: SafeGainConfig = SafeGainConfig(), initialGain: Float = 1) {
        self.config = config
        self.currentGain = min(max(initialGain, 1), config.maxGain)
    }

    public mutating func process(samples: [Float], requestedGain: Float) -> SafeGainResult {
        applySlewedGain(requestedGain)
        let inputLevels = LevelMeter.measure(samples)
        let output = samples.map { sample in
            config.limiter.process((sample.isFinite ? sample : 0) * currentGain)
        }
        let outputLevels = LevelMeter.measure(output)

        return SafeGainResult(
            samples: output,
            appliedGain: currentGain,
            inputLevels: inputLevels,
            outputLevels: outputLevels
        )
    }

    public mutating func analyze(samples: UnsafeBufferPointer<Float32>, requestedGain: Float) -> SafeGainAnalysisResult {
        applySlewedGain(requestedGain)

        guard !samples.isEmpty else {
            return SafeGainAnalysisResult(
                appliedGain: currentGain,
                inputLevels: .silence,
                outputLevels: .silence,
                sampleCount: 0,
                limitedSampleCount: 0
            )
        }

        var inputPeak: Float = 0
        var inputSquares: Double = 0
        var outputPeak: Float = 0
        var outputSquares: Double = 0
        var limitedCount = 0

        for rawSample in samples {
            let inputSample = rawSample.isFinite ? rawSample : 0
            let gainedSample = inputSample * currentGain
            let outputSample = config.limiter.process(gainedSample)

            inputPeak = max(inputPeak, abs(inputSample))
            inputSquares += Double(inputSample * inputSample)
            outputPeak = max(outputPeak, abs(outputSample))
            outputSquares += Double(outputSample * outputSample)

            if outputSample != gainedSample {
                limitedCount += 1
            }
        }

        let count = samples.count
        return SafeGainAnalysisResult(
            appliedGain: currentGain,
            inputLevels: AudioLevels(
                peak: inputPeak,
                rms: Float((inputSquares / Double(count)).squareRoot())
            ),
            outputLevels: AudioLevels(
                peak: outputPeak,
                rms: Float((outputSquares / Double(count)).squareRoot())
            ),
            sampleCount: count,
            limitedSampleCount: limitedCount
        )
    }

    public mutating func process(
        input: UnsafeBufferPointer<Float32>,
        output: UnsafeMutableBufferPointer<Float32>,
        requestedGain: Float
    ) -> SafeGainAnalysisResult {
        applySlewedGain(requestedGain)

        guard !input.isEmpty, !output.isEmpty else {
            for index in output.indices {
                output[index] = 0
            }
            return SafeGainAnalysisResult(
                appliedGain: currentGain,
                inputLevels: .silence,
                outputLevels: .silence,
                sampleCount: 0,
                limitedSampleCount: 0
            )
        }

        let processedCount = min(input.count, output.count)
        var inputPeak: Float = 0
        var inputSquares: Double = 0
        var outputPeak: Float = 0
        var outputSquares: Double = 0
        var limitedCount = 0

        for index in 0..<processedCount {
            let inputSample = input[index].isFinite ? input[index] : 0
            let gainedSample = inputSample * currentGain
            let outputSample = config.limiter.process(gainedSample)
            output[index] = outputSample

            inputPeak = max(inputPeak, abs(inputSample))
            inputSquares += Double(inputSample * inputSample)
            outputPeak = max(outputPeak, abs(outputSample))
            outputSquares += Double(outputSample * outputSample)

            if outputSample != gainedSample {
                limitedCount += 1
            }
        }

        if output.count > processedCount {
            for index in processedCount..<output.count {
                output[index] = 0
            }
        }

        return SafeGainAnalysisResult(
            appliedGain: currentGain,
            inputLevels: AudioLevels(
                peak: inputPeak,
                rms: Float((inputSquares / Double(processedCount)).squareRoot())
            ),
            outputLevels: AudioLevels(
                peak: outputPeak,
                rms: Float((outputSquares / Double(processedCount)).squareRoot())
            ),
            sampleCount: processedCount,
            limitedSampleCount: limitedCount
        )
    }

    private mutating func applySlewedGain(_ requestedGain: Float) {
        let targetGain = min(max(requestedGain.isFinite ? requestedGain : 1, 1), config.maxGain)
        currentGain = slew(from: currentGain, toward: targetGain)
    }

    private func slew(from current: Float, toward target: Float) -> Float {
        let delta = target - current
        let maxStep = delta >= 0 ? config.maxGainRisePerBuffer : config.maxGainFallPerBuffer
        if abs(delta) <= maxStep {
            return target
        }
        return current + (delta > 0 ? maxStep : -maxStep)
    }
}
