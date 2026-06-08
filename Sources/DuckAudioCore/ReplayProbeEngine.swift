import CoreAudio
import Dispatch
import Foundation

public struct ReplayProbeConfiguration: Equatable, Sendable {
    public let durationSeconds: Double
    public let intervalSeconds: Double
    public let speakerOutputEnabled: Bool
    public let lowVolumeConfirmed: Bool
    public let simulatedGain: Float
    public let maxGain: Float
    public let limiterCeiling: Float
    public let autoGain: Bool
    public let headroomRatio: Float

    public init(
        durationSeconds: Double = 10,
        intervalSeconds: Double = 1,
        speakerOutputEnabled: Bool = false,
        lowVolumeConfirmed: Bool = false,
        simulatedGain: Float = 1,
        maxGain: Float = 1,
        limiterCeiling: Float = 0.90,
        autoGain: Bool = false,
        headroomRatio: Float = 0.98
    ) {
        precondition(durationSeconds > 0)
        precondition(intervalSeconds > 0)
        precondition(simulatedGain >= 1)
        precondition(maxGain >= 1)
        precondition(limiterCeiling > 0 && limiterCeiling <= 1)
        precondition(headroomRatio > 0 && headroomRatio <= 1)
        self.durationSeconds = durationSeconds
        self.intervalSeconds = intervalSeconds
        self.speakerOutputEnabled = speakerOutputEnabled
        self.lowVolumeConfirmed = lowVolumeConfirmed
        self.simulatedGain = simulatedGain
        self.maxGain = maxGain
        self.limiterCeiling = limiterCeiling
        self.autoGain = autoGain
        self.headroomRatio = headroomRatio
    }
}

public final class ReplayProbeEngine: @unchecked Sendable {
    private let configuration: ReplayProbeConfiguration
    private let lock = NSLock()
    private var latestSnapshot = TapMeterSnapshot.empty
    private var safeGain: SafeGainStage

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false

    public init(configuration: ReplayProbeConfiguration = ReplayProbeConfiguration()) {
        self.configuration = configuration
        self.safeGain = SafeGainStage(
            config: SafeGainConfig(
                maxGain: configuration.maxGain,
                maxGainStepPerBuffer: 0.25,
                maxGainFallPerBuffer: configuration.maxGain,
                limiter: HardLimiter(ceiling: configuration.limiterCeiling)
            )
        )
    }

    deinit {
        stopIgnoringErrors()
    }

    public func start() throws {
        guard #available(macOS 14.2, *) else {
            throw Phase0Error.unsupportedOS
        }

        try validateSafetyGate()

        let excludedProcesses = try exclusionProcessObjectIDs()
        tapID = try createTap(excluding: excludedProcesses)
        aggregateDeviceID = try createAggregateDevice(for: tapID)
        try createIOProc()
        try AudioHardwareError.check(AudioDeviceStart(aggregateDeviceID, ioProcID), operation: "AudioDeviceStart")
        isStarted = true
    }

    public func stop() throws {
        var firstError: Error?

        if isStarted {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr {
                firstError = AudioHardwareError(operation: "AudioDeviceStop", status: status)
            }
            isStarted = false
        }

        if let ioProcID {
            let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if status != noErr, firstError == nil {
                firstError = AudioHardwareError(operation: "AudioDeviceDestroyIOProcID", status: status)
            }
            self.ioProcID = nil
        }

        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr, firstError == nil {
                firstError = AudioHardwareError(operation: "AudioHardwareDestroyAggregateDevice", status: status)
            }
            aggregateDeviceID = kAudioObjectUnknown
        }

        if tapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                let status = AudioHardwareDestroyProcessTap(tapID)
                if status != noErr, firstError == nil {
                    firstError = AudioHardwareError(operation: "AudioHardwareDestroyProcessTap", status: status)
                }
            }
            tapID = kAudioObjectUnknown
        }

        if let firstError {
            throw firstError
        }
    }

    public func snapshot() -> TapMeterSnapshot {
        lock.withLock {
            latestSnapshot
        }
    }

    private func stopIgnoringErrors() {
        try? stop()
    }

    private func validateSafetyGate() throws {
        guard configuration.speakerOutputEnabled else {
            return
        }

        guard configuration.lowVolumeConfirmed else {
            throw ReplayProbeError.speakerOutputRequiresLowVolumeConfirmation
        }

        guard configuration.simulatedGain <= 1, configuration.maxGain <= 1 else {
            throw ReplayProbeError.speakerOutputRequiresUnityGain
        }

        let callProcesses = try AudioProcessProbe.inputRunningCallProcesses()
        guard !callProcesses.isEmpty else {
            throw ReplayProbeError.speakerOutputRequiresActiveCall
        }
    }

    private func exclusionProcessObjectIDs() throws -> [AudioObjectID] {
        var excluded = Set<AudioObjectID>()
        if let selfObject = try? AudioProcessProbe.currentProcessObjectID(), selfObject != kAudioObjectUnknown {
            excluded.insert(selfObject)
        }

        for process in try AudioProcessProbe.inputRunningProcesses() where process.callMatch != nil {
            excluded.insert(process.objectID)
        }

        return Array(excluded).sorted()
    }

    @available(macOS 14.2, *)
    private func createTap(excluding excludedProcesses: [AudioObjectID]) throws -> AudioObjectID {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        description.name = "Duck Audio Replay Probe Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior(rawValue: TapCaptureMode.mutedWhenTapped.muteBehaviorRawValue)!

        var newTapID = kAudioObjectUnknown
        try AudioHardwareError.check(
            AudioHardwareCreateProcessTap(description, &newTapID),
            operation: "AudioHardwareCreateProcessTap"
        )
        return newTapID
    }

    private func createAggregateDevice(for tapID: AudioObjectID) throws -> AudioObjectID {
        guard let tapUID = try CoreAudioProperty.readCFString(
            objectID: tapID,
            address: CoreAudioProperty.address(kAudioTapPropertyUID)
        ) else {
            throw TapMeterError.missingTapUID
        }

        let aggregateUID = "dev.mrrockysl.duckaudio.replayprobe.\(UUID().uuidString)"
        let tapDescription: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: 1,
            kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMediumQuality
        ]
        var aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "Duck Audio Replay Probe",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tapDescription],
            kAudioAggregateDeviceTapAutoStartKey: 1
        ]

        if configuration.speakerOutputEnabled {
            let outputDevice = try AudioDeviceProbe.defaultOutputDeviceInfo()
            guard let outputUID = outputDevice.uid else {
                throw ReplayProbeError.missingOutputDeviceUID
            }

            let subDeviceDescription: [String: Any] = [
                kAudioSubDeviceUIDKey: outputUID,
                kAudioSubDeviceDriftCompensationKey: 0
            ]
            aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = [subDeviceDescription]
            aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
        }

        var newAggregateID = kAudioObjectUnknown
        try AudioHardwareError.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        return newAggregateID
    }

    private func createIOProc() throws {
        let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.replayprobe.ioproc")
        var newIOProcID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, outputData, _ in
            self?.consume(inputData: inputData, outputData: outputData)
        }

        try AudioHardwareError.check(
            AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, queue, block),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newIOProcID
    }

    private func consume(inputData: UnsafePointer<AudioBufferList>?, outputData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let inputData else {
            zero(outputData: outputData)
            return
        }

        let measurement = configuration.speakerOutputEnabled
            ? measureAndReplay(inputData: inputData, outputData: outputData)
            : measureAndSilence(inputData: inputData, outputData: outputData)

        lock.withLock {
            latestSnapshot = TapMeterSnapshot(
                callbackCount: latestSnapshot.callbackCount + 1,
                totalFrames: latestSnapshot.totalFrames + UInt64(measurement.frameCount),
                lastFrameCount: measurement.frameCount,
                peak: measurement.inputLevels.peak,
                rms: measurement.inputLevels.rms,
                requestedGain: measurement.requestedGain,
                simulatedGain: measurement.appliedGain,
                simulatedPeak: measurement.outputLevels.peak,
                simulatedRMS: measurement.outputLevels.rms,
                sampleCount: measurement.sampleCount,
                limitedSampleCount: measurement.limitedSampleCount,
                maxRawPeak: max(latestSnapshot.maxRawPeak, measurement.inputLevels.peak),
                maxSimulatedPeak: max(latestSnapshot.maxSimulatedPeak, measurement.outputLevels.peak),
                totalSampleCount: latestSnapshot.totalSampleCount + UInt64(measurement.sampleCount),
                totalLimitedSampleCount: latestSnapshot.totalLimitedSampleCount + UInt64(measurement.limitedSampleCount)
            )
        }
    }

    private func measureAndSilence(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) -> ReplayProbeMeasurement {
        zero(outputData: outputData)

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        return measure(inputBuffers: inputBuffers)
    }

    private func measureAndReplay(
        inputData: UnsafePointer<AudioBufferList>,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) -> ReplayProbeMeasurement {
        guard let outputData else {
            return measureAndSilence(inputData: inputData, outputData: nil)
        }

        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        var measurement = ReplayProbeMeasurement.empty
        var outputIndex = 0

        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData, inputBuffer.mDataByteSize > 0 else {
                continue
            }
            guard outputIndex < outputBuffers.count else {
                break
            }

            let inputCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard inputCount > 0 else {
                continue
            }

            let outputBuffer = outputBuffers[outputIndex]
            outputIndex += 1

            guard let outputData = outputBuffer.mData, outputBuffer.mDataByteSize > 0 else {
                continue
            }

            let outputCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard outputCount > 0 else {
                continue
            }

            let inputSamples = inputData.bindMemory(to: Float32.self, capacity: inputCount)
            let outputSamples = outputData.bindMemory(to: Float32.self, capacity: outputCount)
            let inputPointer = UnsafeBufferPointer(start: inputSamples, count: inputCount)
            let requestedGain = requestedGainForBuffer(inputPointer)
            let analysis = safeGain.process(
                input: inputPointer,
                output: UnsafeMutableBufferPointer(start: outputSamples, count: outputCount),
                requestedGain: requestedGain
            )

            measurement.accumulate(
                analysis: analysis,
                frameCount: UInt32(inputCount) / max(inputBuffer.mNumberChannels, 1),
                requestedGain: requestedGain
            )
        }

        if outputIndex < outputBuffers.count {
            for index in outputIndex..<outputBuffers.count {
                zero(buffer: outputBuffers[index])
            }
        }

        return measurement
    }

    private func measure(inputBuffers: UnsafeMutableAudioBufferListPointer) -> ReplayProbeMeasurement {
        var measurement = ReplayProbeMeasurement.empty

        for inputBuffer in inputBuffers {
            guard let inputData = inputBuffer.mData, inputBuffer.mDataByteSize > 0 else {
                continue
            }

            let inputCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard inputCount > 0 else {
                continue
            }

            let inputSamples = inputData.bindMemory(to: Float32.self, capacity: inputCount)
            let inputPointer = UnsafeBufferPointer(start: inputSamples, count: inputCount)
            let requestedGain = requestedGainForBuffer(inputPointer)
            let analysis = safeGain.analyze(samples: inputPointer, requestedGain: requestedGain)
            measurement.accumulate(
                analysis: analysis,
                frameCount: UInt32(inputCount) / max(inputBuffer.mNumberChannels, 1),
                requestedGain: requestedGain
            )
        }

        return measurement
    }

    private func requestedGainForBuffer(_ samples: UnsafeBufferPointer<Float32>) -> Float {
        guard configuration.autoGain else {
            return configuration.simulatedGain
        }

        var peak: Float = 0
        for rawSample in samples {
            let sample = rawSample.isFinite ? rawSample : 0
            peak = max(peak, abs(sample))
        }

        guard peak > 0 else {
            return configuration.simulatedGain
        }

        let headroomGain = (configuration.limiterCeiling * configuration.headroomRatio) / peak
        return min(configuration.simulatedGain, max(1, headroomGain))
    }

    private func zero(outputData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let outputData else {
            return
        }

        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)
        for outputBuffer in outputBuffers {
            zero(buffer: outputBuffer)
        }
    }

    private func zero(buffer: AudioBuffer) {
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
            return
        }
        memset(data, 0, Int(buffer.mDataByteSize))
    }
}

private struct ReplayProbeMeasurement {
    var frameCount: UInt32
    var requestedGain: Float
    var appliedGain: Float
    var inputPeak: Float
    var inputSquares: Double
    var outputPeak: Float
    var outputSquares: Double
    var sampleCount: Int
    var limitedSampleCount: Int

    static let empty = ReplayProbeMeasurement(
        frameCount: 0,
        requestedGain: 1,
        appliedGain: 1,
        inputPeak: 0,
        inputSquares: 0,
        outputPeak: 0,
        outputSquares: 0,
        sampleCount: 0,
        limitedSampleCount: 0
    )

    var inputLevels: AudioLevels {
        AudioLevels(
            peak: inputPeak,
            rms: sampleCount > 0 ? Float((inputSquares / Double(sampleCount)).squareRoot()) : 0
        )
    }

    var outputLevels: AudioLevels {
        AudioLevels(
            peak: outputPeak,
            rms: sampleCount > 0 ? Float((outputSquares / Double(sampleCount)).squareRoot()) : 0
        )
    }

    mutating func accumulate(
        analysis: SafeGainAnalysisResult,
        frameCount: UInt32,
        requestedGain: Float
    ) {
        self.frameCount = max(self.frameCount, frameCount)
        self.requestedGain = requestedGain
        self.appliedGain = analysis.appliedGain
        self.inputPeak = max(self.inputPeak, analysis.inputLevels.peak)
        self.outputPeak = max(self.outputPeak, analysis.outputLevels.peak)
        self.inputSquares += Double(analysis.inputLevels.rms * analysis.inputLevels.rms) * Double(analysis.sampleCount)
        self.outputSquares += Double(analysis.outputLevels.rms * analysis.outputLevels.rms) * Double(analysis.sampleCount)
        self.sampleCount += analysis.sampleCount
        self.limitedSampleCount += analysis.limitedSampleCount
    }
}

public enum ReplayProbeError: Error, CustomStringConvertible, Sendable {
    case missingOutputDeviceUID
    case speakerOutputRequiresLowVolumeConfirmation
    case speakerOutputRequiresUnityGain
    case speakerOutputRequiresActiveCall

    public var description: String {
        switch self {
        case .missingOutputDeviceUID:
            "default output device did not expose a UID"
        case .speakerOutputRequiresLowVolumeConfirmation:
            "speaker output requires --low-volume-confirmed after setting system volume to 20% or lower"
        case .speakerOutputRequiresUnityGain:
            "speaker output probe currently allows only --gain 1 and --max-gain 1"
        case .speakerOutputRequiresActiveCall:
            "speaker output requires an active known call process"
        }
    }
}
