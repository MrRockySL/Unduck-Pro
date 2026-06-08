import CoreAudio
import Dispatch
import Foundation

/// Configuration for the production `TapEngine`.
public struct TapEngineConfiguration: Equatable, Sendable {
    /// The gain to apply when a call is active. Set to the measured duck ratio
    /// (or a safe fraction of it). Ignored when no call is detected.
    public let callGain: Float
    /// Maximum gain the SafeGainStage will ever apply.
    public let maxGain: Float
    /// Hard limiter ceiling. Samples above this are clamped.
    public let limiterCeiling: Float
    /// Slew rate for gain increases (per IO callback buffer).
    public let gainRisePerBuffer: Float
    /// Slew rate for gain decreases — fast so transients are safe.
    public let gainFallPerBuffer: Float
    /// Whether to use auto-headroom (lower gain for hot buffers).
    public let autoHeadroom: Bool
    /// Headroom ratio for auto-headroom mode.
    public let headroomRatio: Float

    public init(
        callGain: Float = 1,
        maxGain: Float = 40,
        limiterCeiling: Float = 0.90,
        gainRisePerBuffer: Float = 0.25,
        gainFallPerBuffer: Float = 40,
        autoHeadroom: Bool = true,
        headroomRatio: Float = 0.98
    ) {
        precondition(callGain >= 1)
        precondition(maxGain >= 1)
        precondition(limiterCeiling > 0 && limiterCeiling <= 1)
        precondition(gainRisePerBuffer > 0)
        precondition(gainFallPerBuffer > 0)
        precondition(headroomRatio > 0 && headroomRatio <= 1)
        self.callGain = callGain
        self.maxGain = maxGain
        self.limiterCeiling = limiterCeiling
        self.gainRisePerBuffer = gainRisePerBuffer
        self.gainFallPerBuffer = gainFallPerBuffer
        self.autoHeadroom = autoHeadroom
        self.headroomRatio = headroomRatio
    }
}

/// Snapshot of the engine's current metering state.
public struct TapEngineSnapshot: Sendable {
    public let callbackCount: UInt64
    public let totalFrames: UInt64
    public let inputPeak: Float
    public let outputPeak: Float
    public let appliedGain: Float
    public let limitedSampleCount: UInt64
    public let totalSampleCount: UInt64
    public let isInCall: Bool
    public let requestedGain: Float

    public static let empty = TapEngineSnapshot(
        callbackCount: 0, totalFrames: 0,
        inputPeak: 0, outputPeak: 0, appliedGain: 1,
        limitedSampleCount: 0, totalSampleCount: 0,
        isInCall: false, requestedGain: 1
    )
}

/// The production audio engine for Duck Audio.
///
/// Creates a muted process tap (excluding call apps and self), builds a private
/// aggregate device that includes the default speakers, and runs an IOProc that
/// copies tap input → SafeGain → hard limiter → speakers.
///
/// Gain is driven by a `CallWatcher`:
/// - **No call:** gain = 1 (passthrough, though the tap is muted so the normal
///   output path is silenced — engine should only be active during a call in
///   production, but for safety we default to unity)
/// - **In call:** gain = `callGain` (the compensation factor)
public final class TapEngine: @unchecked Sendable {
    public let configuration: TapEngineConfiguration
    public let callWatcher: CallWatcher

    private let lock = NSLock()
    private var safeGain: SafeGainStage
    private var _snapshot = TapEngineSnapshot.empty
    private var _requestedGain: Float = 1

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var currentExcludedIDs: Set<AudioObjectID> = []
    private var unduckTimer: DispatchSourceTimer?
    private var outputDeviceID: AudioObjectID = kAudioObjectUnknown

    public init(configuration: TapEngineConfiguration, callWatcher: CallWatcher) {
        self.configuration = configuration
        self.callWatcher = callWatcher
        self.safeGain = SafeGainStage(
            config: SafeGainConfig(
                maxGain: configuration.maxGain,
                maxGainStepPerBuffer: configuration.gainRisePerBuffer,
                maxGainFallPerBuffer: configuration.gainFallPerBuffer,
                limiter: HardLimiter(ceiling: configuration.limiterCeiling)
            )
        )
    }

    deinit {
        stopIgnoringErrors()
    }

    /// Start the engine. Creates tap, aggregate device, and IOProc.
    public func start() throws {
        guard #available(macOS 14.2, *) else {
            throw Phase0Error.unsupportedOS
        }

        let callState = callWatcher.currentState
        let excluded = buildExclusionSet(callState: callState)
        currentExcludedIDs = excluded

        // Set initial gain based on call state
        lock.withLock {
            _requestedGain = callState.isInCall ? configuration.callGain : 1
            _snapshot = TapEngineSnapshot(
                callbackCount: 0, totalFrames: 0,
                inputPeak: 0, outputPeak: 0, appliedGain: 1,
                limitedSampleCount: 0, totalSampleCount: 0,
                isInCall: callState.isInCall, requestedGain: _requestedGain
            )
        }

        outputDeviceID = (try? AudioDeviceProbe.defaultOutputDeviceID()) ?? kAudioObjectUnknown
        tapID = try createTap(excluding: Array(excluded))
        aggregateDeviceID = try createAggregateDevice(for: tapID)
        try createIOProc()
        try AudioHardwareError.check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            operation: "AudioDeviceStart"
        )
        isStarted = true

        // Attempt to un-duck both the aggregate device and the real output device.
        // AudioDeviceDuck is a private API that SoundSource uses; calling with
        // level=1.0 tells macOS "no ducking on this device."
        applyUnduck()
        startUnduckTimer()
    }

    /// Stop the engine. Tears down IOProc, aggregate device, and tap.
    public func stop() throws {
        unduckTimer?.cancel()
        unduckTimer = nil

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

    /// Get the latest metering snapshot. Thread-safe.
    public func snapshot() -> TapEngineSnapshot {
        lock.withLock { _snapshot }
    }

    /// Update the requested gain based on call state. Called by CallWatcher delegate.
    public func updateCallState(_ state: CallState) {
        lock.withLock {
            _requestedGain = state.isInCall ? configuration.callGain : 1
        }
    }

    /// Rebuild the tap with a new exclusion set. Called when call processes change.
    /// This briefly interrupts audio (a few ms of silence) but is safe.
    public func rebuildTap(for callState: CallState) throws {
        guard #available(macOS 14.2, *) else { return }
        guard isStarted else { return }

        let newExcluded = buildExclusionSet(callState: callState)
        guard newExcluded != currentExcludedIDs else { return }

        // Stop the current IOProc
        if isStarted {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            isStarted = false
        }

        // Destroy old IOProc
        if let ioProcID {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            self.ioProcID = nil
        }

        // Destroy old aggregate
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }

        // Destroy old tap
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }

        // Rebuild with new exclusion set
        currentExcludedIDs = newExcluded
        tapID = try createTap(excluding: Array(newExcluded))
        aggregateDeviceID = try createAggregateDevice(for: tapID)
        try createIOProc()
        try AudioHardwareError.check(
            AudioDeviceStart(aggregateDeviceID, ioProcID),
            operation: "AudioDeviceStart (rebuild)"
        )
        isStarted = true
    }

    // MARK: - Un-duck

    /// Attempt to counteract macOS call ducking using every known mechanism:
    /// 1. AudioDeviceDuck(device, 1.0) — private API, tells macOS "no duck"
    /// 2. Write to the 'duck' property — settable 16-byte property on output devices
    private func applyUnduck() {
        applyAudioDeviceDuck()
        writeDuckProperty()
    }

    /// Call the private AudioDeviceDuck function.
    private func applyAudioDeviceDuck() {
        typealias AudioDeviceDuckFunc = @convention(c) (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

        guard let handle = dlopen(nil, RTLD_NOW) else { return }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "AudioDeviceDuck") else {
            fputs("[unduck] AudioDeviceDuck symbol NOT found\n", stderr)
            return
        }
        let audioDuck = unsafeBitCast(sym, to: AudioDeviceDuckFunc.self)

        if aggregateDeviceID != kAudioObjectUnknown {
            let s = audioDuck(aggregateDeviceID, 1.0, nil, 0)
            fputs("[unduck] AudioDeviceDuck(agg=\(aggregateDeviceID),1.0) → \(s)\n", stderr)
        }

        if outputDeviceID != kAudioObjectUnknown {
            let s = audioDuck(outputDeviceID, 1.0, nil, 0)
            fputs("[unduck] AudioDeviceDuck(out=\(outputDeviceID),1.0) → \(s)\n", stderr)
        }
    }

    /// Write to the settable 'duck' property on the output device.
    /// The property is 16 bytes = 4 Float32. We write [1.0, 0.0, 0.0, 0.0]
    /// hoping Float32[0] is the duck level (1.0 = no ducking).
    private func writeDuckProperty() {
        let selector = FourCC.make("duck")

        // Try writing on both output and global scopes
        for (scope, scopeName) in [
            (kAudioDevicePropertyScopeOutput, "output"),
            (kAudioObjectPropertyScopeGlobal, "global")
        ] {
            writeDuckPropertyOnDevice(outputDeviceID, scope: scope, scopeName: scopeName, selector: selector)
            writeDuckPropertyOnDevice(aggregateDeviceID, scope: scope, scopeName: scopeName, selector: selector)
        }
    }

    private func writeDuckPropertyOnDevice(
        _ deviceID: AudioObjectID,
        scope: AudioObjectPropertyScope,
        scopeName: String,
        selector: AudioObjectPropertySelector
    ) {
        guard deviceID != kAudioObjectUnknown else { return }

        var address = CoreAudioProperty.address(selector, scope: scope)
        guard AudioObjectHasProperty(deviceID, &address) else { return }

        // Check if settable
        var isSettable: DarwinBoolean = false
        let settableStatus = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        guard settableStatus == noErr, isSettable.boolValue else { return }

        // Write [1.0, 0.0, 0.0, 0.0] — 16 bytes
        var values: [Float32] = [1.0, 0.0, 0.0, 0.0]
        let dataSize = UInt32(MemoryLayout<Float32>.stride * values.count)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, dataSize, buffer.baseAddress!)
        }
        if status != noErr {
            fputs("[unduck] duck property write [\(scopeName)] on device \(deviceID) → status \(status)\n", stderr)
        }
    }

    /// Repeatedly apply un-duck every 500ms.
    private func startUnduckTimer() {
        let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.unduck", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            self?.applyUnduck()
        }
        timer.resume()
        unduckTimer = timer
    }

    // MARK: - Private

    private func stopIgnoringErrors() {
        try? stop()
    }

    private func buildExclusionSet(callState: CallState) -> Set<AudioObjectID> {
        var excluded = callState.excludedObjectIDs
        if let selfObject = try? AudioProcessProbe.currentProcessObjectID(),
           selfObject != kAudioObjectUnknown {
            excluded.insert(selfObject)
        }
        return excluded
    }

    @available(macOS 14.2, *)
    private func createTap(excluding excludedProcesses: [AudioObjectID]) throws -> AudioObjectID {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
        description.name = "Duck Audio Engine Tap"
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

        let outputDevice = try AudioDeviceProbe.defaultOutputDeviceInfo()
        guard let outputUID = outputDevice.uid else {
            throw ReplayProbeError.missingOutputDeviceUID
        }

        let aggregateUID = "dev.mrrockysl.duckaudio.engine.\(UUID().uuidString)"
        let tapDescription: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: 1,
            kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationMediumQuality
        ]
        let subDeviceDescription: [String: Any] = [
            kAudioSubDeviceUIDKey: outputUID,
            kAudioSubDeviceDriftCompensationKey: 0
        ]
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "Duck Audio Engine",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: [tapDescription],
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [subDeviceDescription],
            kAudioAggregateDeviceMainSubDeviceKey: outputUID
        ]

        var newAggregateID = kAudioObjectUnknown
        try AudioHardwareError.check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        return newAggregateID
    }

    private func createIOProc() throws {
        let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.engine.ioproc")
        var newIOProcID: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, outputData, _ in
            self?.ioCallback(inputData: inputData, outputData: outputData)
        }

        try AudioHardwareError.check(
            AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, aggregateDeviceID, queue, block),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newIOProcID
    }

    private func ioCallback(
        inputData: UnsafePointer<AudioBufferList>?,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let inputData, let outputData else {
            zero(outputData: outputData)
            return
        }

        let requestedGain = lock.withLock { _requestedGain }
        let inputBuffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        let outputBuffers = UnsafeMutableAudioBufferListPointer(outputData)

        var totalInputPeak: Float = 0
        var totalOutputPeak: Float = 0
        var totalSamples: UInt64 = 0
        var totalLimited: UInt64 = 0
        var totalFrames: UInt32 = 0
        var appliedGain: Float = 1
        var outputIndex = 0

        for inputBuffer in inputBuffers {
            guard let inData = inputBuffer.mData, inputBuffer.mDataByteSize > 0 else {
                continue
            }
            guard outputIndex < outputBuffers.count else { break }

            let inputCount = Int(inputBuffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard inputCount > 0 else { continue }

            let outputBuffer = outputBuffers[outputIndex]
            outputIndex += 1

            guard let outData = outputBuffer.mData, outputBuffer.mDataByteSize > 0 else {
                continue
            }

            let outputCount = Int(outputBuffer.mDataByteSize) / MemoryLayout<Float32>.stride
            guard outputCount > 0 else { continue }

            let inputSamples = inData.bindMemory(to: Float32.self, capacity: inputCount)
            let outputSamples = outData.bindMemory(to: Float32.self, capacity: outputCount)
            let inputPointer = UnsafeBufferPointer(start: inputSamples, count: inputCount)

            // Auto-headroom: lower gain for hot buffers
            let effectiveGain: Float
            if configuration.autoHeadroom {
                var peak: Float = 0
                for sample in inputPointer {
                    let s = sample.isFinite ? sample : 0
                    peak = max(peak, abs(s))
                }
                if peak > 0 {
                    let headroomGain = (configuration.limiterCeiling * configuration.headroomRatio) / peak
                    effectiveGain = min(requestedGain, max(1, headroomGain))
                } else {
                    effectiveGain = requestedGain
                }
            } else {
                effectiveGain = requestedGain
            }

            let analysis = safeGain.process(
                input: inputPointer,
                output: UnsafeMutableBufferPointer(start: outputSamples, count: outputCount),
                requestedGain: effectiveGain
            )

            totalInputPeak = max(totalInputPeak, analysis.inputLevels.peak)
            totalOutputPeak = max(totalOutputPeak, analysis.outputLevels.peak)
            totalSamples += UInt64(analysis.sampleCount)
            totalLimited += UInt64(analysis.limitedSampleCount)
            totalFrames = max(totalFrames, UInt32(inputCount) / max(inputBuffer.mNumberChannels, 1))
            appliedGain = analysis.appliedGain
        }

        // Zero remaining output buffers
        if outputIndex < outputBuffers.count {
            for index in outputIndex..<outputBuffers.count {
                zero(buffer: outputBuffers[index])
            }
        }

        // Update snapshot
        lock.withLock {
            _snapshot = TapEngineSnapshot(
                callbackCount: _snapshot.callbackCount + 1,
                totalFrames: _snapshot.totalFrames + UInt64(totalFrames),
                inputPeak: totalInputPeak,
                outputPeak: totalOutputPeak,
                appliedGain: appliedGain,
                limitedSampleCount: _snapshot.limitedSampleCount + totalLimited,
                totalSampleCount: _snapshot.totalSampleCount + totalSamples,
                isInCall: _requestedGain > 1,
                requestedGain: _requestedGain
            )
        }
    }

    private func zero(outputData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let outputData else { return }
        let bufferList = UnsafeMutableAudioBufferListPointer(outputData)
        for buffer in bufferList {
            zero(buffer: buffer)
        }
    }

    private func zero(buffer: AudioBuffer) {
        guard let data = buffer.mData, buffer.mDataByteSize > 0 else { return }
        memset(data, 0, Int(buffer.mDataByteSize))
    }
}
