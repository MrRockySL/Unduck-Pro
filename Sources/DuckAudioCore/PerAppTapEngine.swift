import CoreAudio
import Dispatch
import Foundation

/// One process whose output is currently controlled by the mixer.
public struct TappedApp: Sendable, Equatable {
    public let index: Int
    public let processObjectID: AudioObjectID
    public let pid: pid_t
    public let bundleID: String?
    public let isCall: Bool
}

/// Deterministic aggregate-buffer mapping shared by the realtime callback and
/// the self-test. Aggregate tap streams are the trailing input streams.
public enum PerAppBufferRouting {
    public static func inputIndex(
        inputBufferCount: Int,
        outputBufferCount: Int,
        outputIndex: Int
    ) -> Int? {
        guard inputBufferCount > 0,
              outputBufferCount > 0,
              outputIndex >= 0,
              outputIndex < outputBufferCount else { return nil }
        let index = inputBufferCount > outputBufferCount
            ? inputBufferCount - outputBufferCount + outputIndex
            : outputIndex
        return index < inputBufferCount ? index : nil
    }
}

/// Per-process volume engine.
///
/// Each Core Audio process owns an independent tap, private aggregate device,
/// and IOProc. This is intentionally different from the original shared
/// aggregate: a shared aggregate exposes a stream-oriented buffer list whose
/// ordering is not a reliable process-to-slider mapping. Independent pipelines
/// make the routing unambiguous, so FaceTime and its helper processes can be
/// adjusted with the same gain path as browsers and media apps.
public final class PerAppTapEngine: @unchecked Sendable {
    public let limiterCeiling: Float
    private let maxTaps = 32

    private let lock = NSLock()
    private var pipelines: [AudioObjectID: ProcessTapPipeline] = [:]
    private var _tapped: [TappedApp] = []
    private var outputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var outputDeviceUID: String?
    private var unduckTimer: DispatchSourceTimer?

    /// Process object IDs of apps actively participating in a call. They are
    /// tapped like other output processes, but flagged for UI grouping.
    public var excludedCallIDs: Set<AudioObjectID> = []
    /// Logical families (FaceTime, Zoom, Chrome/Meet…) currently using input.
    /// This associates output-only helpers with the process that owns the mic.
    public var activeCallFamilies: Set<String> = []

    public init(limiterCeiling: Float = 0.9) {
        self.limiterCeiling = limiterCeiling
    }

    deinit {
        try? stop()
    }

    // MARK: - Public control

    public func start() throws {
        guard #available(macOS 14.2, *) else { throw Phase0Error.unsupportedOS }

        // A single process can transiently reject tap creation while its audio
        // stream is starting. Keep the engine alive so the manager can retry
        // that process without dropping every pipeline that did start.
        do {
            try rebuild()
        } catch {
            fputs("[engine] initial per-process tap setup incomplete: \(error)\n", stderr)
        }
        startUnduckTimer()
    }

    public func stop() throws {
        unduckTimer?.cancel(); unduckTimer = nil

        let active = lock.withLock { () -> [ProcessTapPipeline] in
            let current = Array(pipelines.values)
            pipelines.removeAll()
            _tapped.removeAll()
            return current
        }
        var firstError: Error?
        for pipeline in active {
            do { try pipeline.stop() }
            catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }

    public var tappedApps: [TappedApp] { lock.withLock { _tapped } }

    public func setGain(_ gain: Float, forProcess objectID: AudioObjectID) {
        lock.withLock { pipelines[objectID]?.gain = max(0, gain) }
    }

    public func setMuted(_ muted: Bool, forProcess objectID: AudioObjectID) {
        lock.withLock { pipelines[objectID]?.isMuted = muted }
    }

    public func capturedPeak(index: Int) -> Float {
        lock.withLock {
            guard let app = _tapped.first(where: { $0.index == index }) else { return 0 }
            return pipelines[app.processObjectID]?.capturedPeak ?? 0
        }
    }

    /// Diff the live process set. Existing pipelines stay running; only added,
    /// removed, or output-device-affected processes are touched. This prevents a
    /// FaceTime transition from tearing down YouTube's otherwise healthy tap.
    public func rebuild() throws {
        guard #available(macOS 14.2, *) else { return }

        let output = try AudioDeviceProbe.defaultOutputDeviceInfo()
        guard let outputUID = output.uid else { throw ReplayProbeError.missingOutputDeviceUID }
        outputDeviceID = output.id

        let me = (try? AudioProcessProbe.currentProcessObjectID()) ?? kAudioObjectUnknown
        let allOutputs = (try? AudioProcessProbe.outputRunningProcesses()) ?? []
        let prioritized = allOutputs.sorted { lhs, rhs in
            let lhsCall = isLiveCallProcess(lhs)
            let rhsCall = isLiveCallProcess(rhs)
            if lhsCall != rhsCall { return lhsCall }
            return (lhs.bundleID ?? lhs.processName ?? "") < (rhs.bundleID ?? rhs.processName ?? "")
        }
        let desiredProcesses = Array(prioritized.filter { $0.objectID != me }.prefix(maxTaps))
        let desiredIDs = Set(desiredProcesses.map(\.objectID))

        let deviceChanged = self.outputDeviceUID != nil && self.outputDeviceUID != outputUID
        self.outputDeviceUID = outputUID

        let existing = lock.withLock { pipelines }
        let removedIDs = deviceChanged ? Set(existing.keys) : Set(existing.keys).subtracting(desiredIDs)

        var firstError: Error?
        for objectID in removedIDs {
            guard let pipeline = lock.withLock({ pipelines.removeValue(forKey: objectID) }) else { continue }
            do { try pipeline.stop() }
            catch { if firstError == nil { firstError = error } }
        }

        for process in desiredProcesses {
            if lock.withLock({ pipelines[process.objectID] != nil }) { continue }

            let pipeline = ProcessTapPipeline(
                processObjectID: process.objectID,
                outputDeviceID: output.id,
                outputDeviceUID: outputUID,
                sampleRate: output.nominalSampleRate ?? 48_000,
                limiterCeiling: limiterCeiling
            )
            do {
                try pipeline.start()
                lock.withLock { pipelines[process.objectID] = pipeline }
                let bundle = process.bundleID ?? "unknown"
                let name = process.processName ?? "unknown"
                let callRole = isLiveCallProcess(process) ? "call" : "media"
                print(
                    "[engine] controlling object=\(process.objectID) pid=\(process.pid ?? -1) "
                        + "bundle=\(bundle) name=\(name) role=\(callRole)"
                )
            } catch {
                fputs("[engine] tap creation failed for process \(process.objectID): \(error)\n", stderr)
                if firstError == nil { firstError = error }
            }
        }

        let activeIDs = lock.withLock { Set(pipelines.keys) }
        let metadata = desiredProcesses.filter { activeIDs.contains($0.objectID) }
        lock.withLock {
            _tapped = metadata.enumerated().map { index, process in
                TappedApp(
                    index: index,
                    processObjectID: process.objectID,
                    pid: process.pid ?? -1,
                    bundleID: process.bundleID,
                    isCall: isLiveCallProcess(process)
                )
            }
        }

        applyUnduck()
        if let firstError { throw firstError }
    }

    private func isLiveCallProcess(_ process: AudioProcessInfo) -> Bool {
        if excludedCallIDs.contains(process.objectID) { return true }
        guard let family = process.callMatch?.family else { return false }
        return activeCallFamilies.contains(family)
    }

    // MARK: - Un-duck

    private typealias DuckFn = @convention(c)
        (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

    private static let audioDeviceDuck: DuckFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else { return nil }
        return unsafeBitCast(symbol, to: DuckFn.self)
    }()

    private func applyUnduck() {
        let aggregateIDs = lock.withLock { pipelines.values.map(\.aggregateDeviceID) }
        if let duck = Self.audioDeviceDuck {
            if outputDeviceID != kAudioObjectUnknown { _ = duck(outputDeviceID, 1.0, nil, 0) }
            for aggregateID in aggregateIDs where aggregateID != kAudioObjectUnknown {
                _ = duck(aggregateID, 1.0, nil, 0)
            }
        }
        writeDuckProperty(outputDeviceID)
        for aggregateID in aggregateIDs { writeDuckProperty(aggregateID) }
    }

    private func writeDuckProperty(_ deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        for scope in [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            var address = CoreAudioProperty.address(FourCC.make("duck"), scope: scope)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var values: [Float32] = [1.0, 0.0, 0.0, 0.0]
            let size = UInt32(MemoryLayout<Float32>.stride * values.count)
            _ = values.withUnsafeMutableBufferPointer {
                AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, $0.baseAddress!)
            }
        }
    }

    private func startUnduckTimer() {
        let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.perapp.unduck", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.applyUnduck() }
        timer.resume()
        unduckTimer = timer
    }
}

/// Owns one unambiguous process → gain → output route.
private final class ProcessTapPipeline: @unchecked Sendable {
    let processObjectID: AudioObjectID
    let outputDeviceID: AudioObjectID
    let outputDeviceUID: String
    let limiterCeiling: Float
    private let rampCoefficient: Float

    private let gainStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let muteStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let peakStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    private let currentGainStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)

    private var tapID: AudioObjectID = kAudioObjectUnknown
    private(set) var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var isStarted = false

    var gain: Float {
        get { gainStorage.pointee }
        set { gainStorage.pointee = max(0, newValue) }
    }
    var isMuted: Bool {
        get { muteStorage.pointee == 0 }
        set { muteStorage.pointee = newValue ? 0 : 1 }
    }
    var capturedPeak: Float { peakStorage.pointee }

    init(
        processObjectID: AudioObjectID,
        outputDeviceID: AudioObjectID,
        outputDeviceUID: String,
        sampleRate: Float64,
        limiterCeiling: Float
    ) {
        self.processObjectID = processObjectID
        self.outputDeviceID = outputDeviceID
        self.outputDeviceUID = outputDeviceUID
        self.limiterCeiling = limiterCeiling
        self.rampCoefficient = 1 - exp(-1 / (Float(max(sampleRate, 1)) * 0.030))
        gainStorage.initialize(to: 1)
        muteStorage.initialize(to: 1)
        peakStorage.initialize(to: 0)
        currentGainStorage.initialize(to: 1)
    }

    deinit {
        try? stop()
        gainStorage.deinitialize(count: 1); gainStorage.deallocate()
        muteStorage.deinitialize(count: 1); muteStorage.deallocate()
        peakStorage.deinitialize(count: 1); peakStorage.deallocate()
        currentGainStorage.deinitialize(count: 1); currentGainStorage.deallocate()
    }

    func start() throws {
        guard #available(macOS 14.2, *) else { throw Phase0Error.unsupportedOS }

        let description = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        description.name = "Unduck Pro Process \(processObjectID)"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        tapDescription = description

        do {
            try AudioHardwareError.check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "AudioHardwareCreateProcessTap(\(processObjectID))"
            )

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceUIDKey: "dev.mrrockysl.duckaudio.process.\(UUID().uuidString)",
                kAudioAggregateDeviceNameKey: "Unduck Pro Process \(processObjectID)",
                kAudioAggregateDeviceIsPrivateKey: 1,
                kAudioAggregateDeviceIsStackedKey: 1,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: 1
                ]],
                kAudioAggregateDeviceTapAutoStartKey: 1,
                kAudioAggregateDeviceSubDeviceListKey: [[
                    kAudioSubDeviceUIDKey: outputDeviceUID,
                    kAudioSubDeviceDriftCompensationKey: 0
                ]],
                kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
                kAudioAggregateDeviceClockDeviceKey: outputDeviceUID
            ]
            try AudioHardwareError.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: "AudioHardwareCreateAggregateDevice(\(processObjectID))"
            )

            let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.process.\(processObjectID)", qos: .userInitiated)
            let block: AudioDeviceIOBlock = { [weak self] _, inputData, _, outputData, _ in
                self?.render(inputData: inputData, outputData: outputData)
            }
            try AudioHardwareError.check(
                AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, queue, block),
                operation: "AudioDeviceCreateIOProcIDWithBlock(\(processObjectID))"
            )
            try AudioHardwareError.check(
                AudioDeviceStart(aggregateDeviceID, ioProcID),
                operation: "AudioDeviceStart(\(processObjectID))"
            )
            isStarted = true
        } catch {
            destroyResources()
            throw error
        }
    }

    func stop() throws {
        var firstError: Error?

        // Restore the process's native output while the tap is still being read.
        if #available(macOS 14.2, *), isStarted, tapID != kAudioObjectUnknown {
            let status = setTapMuteBehavior(.unmuted)
            if status != noErr {
                firstError = AudioHardwareError(operation: "Restore process tap output", status: status)
            }
            usleep(80_000)
        }

        if let cleanupError = destroyResources(), firstError == nil {
            firstError = cleanupError
        }
        if let firstError { throw firstError }
    }

    @discardableResult
    private func destroyResources() -> Error? {
        var firstError: Error?

        if isStarted, aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioDeviceStop(aggregateDeviceID, ioProcID)
            if status != noErr { firstError = AudioHardwareError(operation: "AudioDeviceStop", status: status) }
            isStarted = false
        }
        if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            if status != noErr, firstError == nil {
                firstError = AudioHardwareError(operation: "AudioDeviceDestroyIOProcID", status: status)
            }
        }
        ioProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            if status != noErr, firstError == nil {
                firstError = AudioHardwareError(operation: "AudioHardwareDestroyAggregateDevice", status: status)
            }
            aggregateDeviceID = kAudioObjectUnknown
        }
        if #available(macOS 14.2, *), tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr, firstError == nil {
                firstError = AudioHardwareError(operation: "AudioHardwareDestroyProcessTap", status: status)
            }
            tapID = kAudioObjectUnknown
        }
        tapDescription = nil
        return firstError
    }

    @available(macOS 14.2, *)
    private func setTapMuteBehavior(_ behavior: CATapMuteBehavior) -> OSStatus {
        guard let tapDescription, tapID != kAudioObjectUnknown else { return noErr }
        tapDescription.muteBehavior = behavior
        var address = CoreAudioProperty.address(kAudioTapPropertyDescription)
        var description: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(tapDescription)
        return AudioObjectSetPropertyData(
            tapID,
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UnsafeRawPointer?>.size),
            &description
        )
    }

    /// RT-safe render path. With one tap per aggregate there is no process-index
    /// lookup: the trailing input buffers are this process and map directly onto
    /// the aggregate's output buffers.
    private func render(
        inputData: UnsafePointer<AudioBufferList>?,
        outputData: UnsafeMutablePointer<AudioBufferList>?
    ) {
        guard let outputData else { return }
        let outputs = UnsafeMutableAudioBufferListPointer(outputData)
        for output in outputs where output.mData != nil {
            memset(output.mData!, 0, Int(output.mDataByteSize))
        }
        guard let inputData else { peakStorage.pointee = 0; return }

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard !inputs.isEmpty, !outputs.isEmpty else { peakStorage.pointee = 0; return }

        let targetGain = gainStorage.pointee * muteStorage.pointee
        var currentGain = currentGainStorage.pointee
        var peak: Float = 0

        for outputIndex in outputs.indices {
            guard let inputIndex = PerAppBufferRouting.inputIndex(
                inputBufferCount: inputs.count,
                outputBufferCount: outputs.count,
                outputIndex: outputIndex
            ),
                  let inputRaw = inputs[inputIndex].mData,
                  let outputRaw = outputs[outputIndex].mData else { continue }

            let input = inputs[inputIndex]
            let output = outputs[outputIndex]
            let inputChannels = max(1, Int(input.mNumberChannels))
            let outputChannels = max(1, Int(output.mNumberChannels))
            let inputSamples = Int(input.mDataByteSize) / MemoryLayout<Float>.stride
            let outputSamples = Int(output.mDataByteSize) / MemoryLayout<Float>.stride
            let frames = min(inputSamples / inputChannels, outputSamples / outputChannels)
            guard frames > 0 else { continue }

            let inputPointer = inputRaw.assumingMemoryBound(to: Float.self)
            let outputPointer = outputRaw.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                currentGain += (targetGain - currentGain) * rampCoefficient
                let inputBase = frame * inputChannels
                let outputBase = frame * outputChannels
                for channel in 0..<outputChannels {
                    let sourceChannel: Int
                    if inputChannels == 1 { sourceChannel = 0 }
                    else { sourceChannel = min(channel, inputChannels - 1) }
                    let source = inputPointer[inputBase + sourceChannel]
                    if abs(source) > peak { peak = abs(source) }
                    let gained = source * currentGain
                    outputPointer[outputBase + channel] = max(-limiterCeiling, min(limiterCeiling, gained))
                }
            }
        }

        currentGainStorage.pointee = currentGain
        peakStorage.pointee = peak
    }
}
