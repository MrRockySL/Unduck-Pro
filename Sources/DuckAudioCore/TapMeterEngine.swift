import CoreAudio
import Dispatch
import Foundation

public enum TapCaptureMode: String, Equatable, Sendable {
    case mutedWhenTapped = "muted-when-tapped"
    case unmuted
    case muted

    var muteBehaviorRawValue: Int {
        switch self {
        case .unmuted:
            0
        case .muted:
            1
        case .mutedWhenTapped:
            2
        }
    }
}

public struct TapMeterConfiguration: Equatable, Sendable {
    public let durationSeconds: Double
    public let intervalSeconds: Double
    public let captureMode: TapCaptureMode
    public let simulatedGain: Float
    public let maxGain: Float
    public let limiterCeiling: Float
    public let autoGain: Bool
    public let headroomRatio: Float

    public init(
        durationSeconds: Double = 30,
        intervalSeconds: Double = 1,
        captureMode: TapCaptureMode = .mutedWhenTapped,
        simulatedGain: Float = 10,
        maxGain: Float = 10,
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
        self.captureMode = captureMode
        self.simulatedGain = simulatedGain
        self.maxGain = maxGain
        self.limiterCeiling = limiterCeiling
        self.autoGain = autoGain
        self.headroomRatio = headroomRatio
    }
}

public struct TapMeterSnapshot: Equatable, Sendable {
    public let callbackCount: UInt64
    public let totalFrames: UInt64
    public let lastFrameCount: UInt32
    public let peak: Float
    public let rms: Float
    public let requestedGain: Float
    public let simulatedGain: Float
    public let simulatedPeak: Float
    public let simulatedRMS: Float
    public let sampleCount: Int
    public let limitedSampleCount: Int
    public let maxRawPeak: Float
    public let maxSimulatedPeak: Float
    public let totalSampleCount: UInt64
    public let totalLimitedSampleCount: UInt64

    public init(
        callbackCount: UInt64,
        totalFrames: UInt64,
        lastFrameCount: UInt32,
        peak: Float,
        rms: Float,
        requestedGain: Float,
        simulatedGain: Float,
        simulatedPeak: Float,
        simulatedRMS: Float,
        sampleCount: Int,
        limitedSampleCount: Int,
        maxRawPeak: Float,
        maxSimulatedPeak: Float,
        totalSampleCount: UInt64,
        totalLimitedSampleCount: UInt64
    ) {
        self.callbackCount = callbackCount
        self.totalFrames = totalFrames
        self.lastFrameCount = lastFrameCount
        self.peak = peak
        self.rms = rms
        self.requestedGain = requestedGain
        self.simulatedGain = simulatedGain
        self.simulatedPeak = simulatedPeak
        self.simulatedRMS = simulatedRMS
        self.sampleCount = sampleCount
        self.limitedSampleCount = limitedSampleCount
        self.maxRawPeak = maxRawPeak
        self.maxSimulatedPeak = maxSimulatedPeak
        self.totalSampleCount = totalSampleCount
        self.totalLimitedSampleCount = totalLimitedSampleCount
    }

    public static let empty = TapMeterSnapshot(
        callbackCount: 0,
        totalFrames: 0,
        lastFrameCount: 0,
        peak: 0,
        rms: 0,
        requestedGain: 1,
        simulatedGain: 1,
        simulatedPeak: 0,
        simulatedRMS: 0,
        sampleCount: 0,
        limitedSampleCount: 0,
        maxRawPeak: 0,
        maxSimulatedPeak: 0,
        totalSampleCount: 0,
        totalLimitedSampleCount: 0
    )
}

public final class TapMeterEngine: @unchecked Sendable {
    private let configuration: TapMeterConfiguration
    private let lock = NSLock()
    private var latestSnapshot = TapMeterSnapshot.empty
    private var safeGain: SafeGainStage

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false

    public init(configuration: TapMeterConfiguration = TapMeterConfiguration()) {
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
        description.name = "Duck Audio Measurement Tap"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior(rawValue: configuration.captureMode.muteBehaviorRawValue)!

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

        let uid = "dev.mrrockysl.duckaudio.tapmeter.\(UUID().uuidString)"
        let tapDescription: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: 1,
            kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMediumQuality
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: "Duck Audio Tap Meter",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tapDescription],
            kAudioAggregateDeviceTapAutoStartKey: 1
        ]

        var newAggregateID = kAudioObjectUnknown
        try AudioHardwareError.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        return newAggregateID
    }

    private func createIOProc() throws {
        let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.tapmeter.ioproc")
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
        zero(outputData: outputData)

        guard let inputData else {
            return
        }

        let measurement = measureAndSimulate(inputData)
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

    private func measureAndSimulate(_ bufferListPointer: UnsafePointer<AudioBufferList>) -> CallbackMeasurement {
        let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferListPointer))
        var peak: Float = 0
        var sumOfSquares: Double = 0
        var simulatedPeak: Float = 0
        var simulatedSquares: Double = 0
        var sampleCount = 0
        var limitedSampleCount = 0
        var frameCount: UInt32 = 0
        var appliedGain = safeGain.currentGain
        var requestedGain = configuration.simulatedGain

        for buffer in bufferList {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }

            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard count > 0 else {
                continue
            }

            frameCount = max(frameCount, UInt32(count) / max(buffer.mNumberChannels, 1))
            let samples = data.bindMemory(to: Float32.self, capacity: count)
            requestedGain = requestedGainForBuffer(UnsafeBufferPointer(start: samples, count: count))
            let analysis = safeGain.analyze(
                samples: UnsafeBufferPointer(start: samples, count: count),
                requestedGain: requestedGain
            )

            appliedGain = analysis.appliedGain
            peak = max(peak, analysis.inputLevels.peak)
            simulatedPeak = max(simulatedPeak, analysis.outputLevels.peak)
            sumOfSquares += Double(analysis.inputLevels.rms * analysis.inputLevels.rms) * Double(analysis.sampleCount)
            simulatedSquares += Double(analysis.outputLevels.rms * analysis.outputLevels.rms) * Double(analysis.sampleCount)
            sampleCount += analysis.sampleCount
            limitedSampleCount += analysis.limitedSampleCount
        }

        return CallbackMeasurement(
            frameCount: frameCount,
            requestedGain: requestedGain,
            appliedGain: appliedGain,
            inputLevels: AudioLevels(
                peak: peak,
                rms: sampleCount > 0 ? Float((sumOfSquares / Double(sampleCount)).squareRoot()) : 0
            ),
            outputLevels: AudioLevels(
                peak: simulatedPeak,
                rms: sampleCount > 0 ? Float((simulatedSquares / Double(sampleCount)).squareRoot()) : 0
            ),
            sampleCount: sampleCount,
            limitedSampleCount: limitedSampleCount
        )
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

        let bufferList = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in bufferList {
            guard let data = buffer.mData, buffer.mDataByteSize > 0 else {
                continue
            }
            memset(data, 0, Int(buffer.mDataByteSize))
        }
    }
}

private struct CallbackMeasurement {
    let frameCount: UInt32
    let requestedGain: Float
    let appliedGain: Float
    let inputLevels: AudioLevels
    let outputLevels: AudioLevels
    let sampleCount: Int
    let limitedSampleCount: Int
}

public enum TapMeterError: Error, CustomStringConvertible, Sendable {
    case missingTapUID

    public var description: String {
        switch self {
        case .missingTapUID:
            "Created tap did not expose a UID"
        }
    }
}
