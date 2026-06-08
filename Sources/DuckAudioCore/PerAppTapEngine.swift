import CoreAudio
import Dispatch
import Foundation

/// One app the engine is currently tapping (for the UI to show a slider).
public struct TappedApp: Sendable, Equatable {
    public let index: Int            // buffer index in the IOProc
    public let processObjectID: AudioObjectID
    public let pid: pid_t
    public let isCall: Bool
}

/// Per-app volume engine (the SoundSource-style mixer).
///
/// Validated design: create ONE private aggregate device whose tap list has
/// **one tap per audio app**. The aggregate then presents **one input buffer per
/// app**, fully isolated. The single IOProc multiplies each app's buffer by that
/// app's gain, sums them, runs the mix through a hard limiter, and writes to the
/// speakers. The global "un-duck" loop keeps everything loud during calls.
///
/// Safety: every app's gain passes through the same hard limiter on the final
/// mix, so no slider can blast the speakers.
public final class PerAppTapEngine: @unchecked Sendable {
    public let limiterCeiling: Float
    private let maxTaps = 32

    private let lock = NSLock()
    private var isStarted = false

    private var tapIDs: [AudioObjectID] = []
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private var outputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var unduckTimer: DispatchSourceTimer?

    /// Apps currently tapped, in buffer order. Read on main thread.
    private var _tapped: [TappedApp] = []
    /// Realtime-read gain + mute, indexed by buffer index (no locks/allocs in IO).
    private let gains: UnsafeMutablePointer<Float>
    private let mutes: UnsafeMutablePointer<Float>   // 1 = audible, 0 = muted
    private let inPeaks: UnsafeMutablePointer<Float>  // per-app captured peak

    /// Process object IDs of the call apps to EXCLUDE (never tap → no bleed).
    public var excludedCallIDs: Set<AudioObjectID> = []

    public init(limiterCeiling: Float = 0.9) {
        self.limiterCeiling = limiterCeiling
        gains = .allocate(capacity: maxTaps); gains.initialize(repeating: 1, count: maxTaps)
        mutes = .allocate(capacity: maxTaps); mutes.initialize(repeating: 1, count: maxTaps)
        inPeaks = .allocate(capacity: maxTaps); inPeaks.initialize(repeating: 0, count: maxTaps)
    }

    deinit {
        try? stop()
        gains.deallocate(); mutes.deallocate(); inPeaks.deallocate()
    }

    // MARK: - Public control

    public func start() throws {
        guard #available(macOS 14.2, *) else { throw Phase0Error.unsupportedOS }
        try rebuild()
        startUnduckTimer()
    }

    public func stop() throws {
        unduckTimer?.cancel(); unduckTimer = nil
        try teardown()
    }

    public var tappedApps: [TappedApp] { lock.withLock { _tapped } }

    /// Set an app's volume (0…~1.5). Applies to every buffer of that app.
    public func setGain(_ gain: Float, forProcess objectID: AudioObjectID) {
        lock.withLock {
            for app in _tapped where app.processObjectID == objectID && app.index < maxTaps {
                gains[app.index] = max(0, gain)
            }
        }
    }

    public func setMuted(_ muted: Bool, forProcess objectID: AudioObjectID) {
        lock.withLock {
            for app in _tapped where app.processObjectID == objectID && app.index < maxTaps {
                mutes[app.index] = muted ? 0 : 1
            }
        }
    }

    public func capturedPeak(index: Int) -> Float { index < maxTaps ? inPeaks[index] : 0 }

    /// Re-scan audio apps and rebuild the taps + aggregate. Call when the set of
    /// playing apps or the call state changes. Briefly interrupts audio.
    public func rebuild() throws {
        guard #available(macOS 14.2, *) else { return }

        // Preserve current per-app gains/mutes by process id across the rebuild.
        let priorGain = lock.withLock { () -> [AudioObjectID: (Float, Float)] in
            var m: [AudioObjectID: (Float, Float)] = [:]
            for app in _tapped where app.index < maxTaps { m[app.processObjectID] = (gains[app.index], mutes[app.index]) }
            return m
        }

        try teardown()

        outputDeviceID = (try? AudioDeviceProbe.defaultOutputDeviceID()) ?? kAudioObjectUnknown

        // Which processes to tap: anything producing output, except the call apps
        // and ourselves.
        let me = (try? AudioProcessProbe.currentProcessObjectID()) ?? kAudioObjectUnknown
        let procs = (try? AudioProcessProbe.outputRunningProcesses()) ?? []
        let toTap = procs.filter { $0.objectID != me && !excludedCallIDs.contains($0.objectID) }
            .prefix(maxTaps)

        var newTaps: [AudioObjectID] = []
        var newTapped: [TappedApp] = []
        var index = 0
        for proc in toTap {
            guard let tap = try? createTap(for: proc.objectID) else { continue }
            newTaps.append(tap)
            // Only treat an app as a live call when it's actually using the
            // microphone — matching by name alone wrongly flags ordinary
            // Chrome/Safari media (YouTube, music) as a call and hides its
            // mixer slider. Real mic calls are already excluded via
            // excludedCallIDs, so anything we tap here is controllable media.
            newTapped.append(TappedApp(index: index, processObjectID: proc.objectID,
                                       pid: proc.pid ?? -1,
                                       isCall: proc.isRunningInput && proc.callMatch != nil))
            index += 1
        }

        guard !newTaps.isEmpty else {
            // Nothing to tap right now — that's fine; we'll rebuild when apps play.
            lock.withLock { _tapped = []; tapIDs = [] }
            return
        }

        let agg = try createAggregateDevice(tapIDs: newTaps)

        lock.withLock {
            tapIDs = newTaps
            _tapped = newTapped
            aggregateDeviceID = agg
            // restore gains/mutes; default 1 for new apps
            for app in newTapped where app.index < maxTaps {
                let (g, mu) = priorGain[app.processObjectID] ?? (1, 1)
                gains[app.index] = g
                mutes[app.index] = mu
            }
        }

        try createIOProc(aggregate: agg)
        try AudioHardwareError.check(AudioDeviceStart(agg, ioProcID), operation: "AudioDeviceStart")
        isStarted = true
        applyUnduck()
    }

    // MARK: - Build helpers

    @available(macOS 14.2, *)
    private func createTap(for processObjectID: AudioObjectID) throws -> AudioObjectID {
        let desc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        desc.name = "Unduck Pro App Tap"
        desc.uuid = UUID()
        desc.isPrivate = true
        desc.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        var tap = kAudioObjectUnknown
        try AudioHardwareError.check(AudioHardwareCreateProcessTap(desc, &tap),
                                     operation: "AudioHardwareCreateProcessTap")
        return tap
    }

    private func createAggregateDevice(tapIDs: [AudioObjectID]) throws -> AudioObjectID {
        let outputDevice = try AudioDeviceProbe.defaultOutputDeviceInfo()
        guard let outputUID = outputDevice.uid else { throw ReplayProbeError.missingOutputDeviceUID }

        var tapList: [[String: Any]] = []
        for tap in tapIDs {
            guard let uid = try CoreAudioProperty.readCFString(
                objectID: tap, address: CoreAudioProperty.address(kAudioTapPropertyUID)
            ) else { continue }
            tapList.append([
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: 1
            ])
        }

        let desc: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "dev.mrrockysl.duckaudio.perapp.\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey: "Unduck Pro Mixer",
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceTapListKey: tapList,
            kAudioAggregateDeviceTapAutoStartKey: 1,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceMainSubDeviceKey: outputUID
        ]
        var agg = kAudioObjectUnknown
        try AudioHardwareError.check(AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg),
                                     operation: "AudioHardwareCreateAggregateDevice")
        return agg
    }

    private func createIOProc(aggregate: AudioObjectID) throws {
        let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.perapp.ioproc")
        var proc: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [weak self] _, inData, _, outData, _ in
            self?.ioCallback(inData: inData, outData: outData)
        }
        try AudioHardwareError.check(
            AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, queue, block),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = proc
    }

    /// Realtime: each input buffer is one app. out = Σ (app[i] × gain[i] × mute[i]),
    /// then hard-limited.
    private func ioCallback(inData: UnsafePointer<AudioBufferList>?,
                            outData: UnsafeMutablePointer<AudioBufferList>?) {
        guard let outData else { return }
        let outs = UnsafeMutableAudioBufferListPointer(outData)
        guard let out = outs.first, let outRaw = out.mData, out.mDataByteSize > 0 else {
            for b in outs { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
            return
        }
        let outCount = Int(out.mDataByteSize) / MemoryLayout<Float>.stride
        let outPtr = outRaw.assumingMemoryBound(to: Float.self)
        for i in 0..<outCount { outPtr[i] = 0 }   // clear the mix

        if let inData {
            let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            for (i, inBuf) in ins.enumerated() where i < maxTaps {
                guard let inRaw = inBuf.mData, inBuf.mDataByteSize > 0 else { continue }
                let n = min(Int(inBuf.mDataByteSize) / MemoryLayout<Float>.stride, outCount)
                let inPtr = inRaw.assumingMemoryBound(to: Float.self)
                let g = gains[i] * mutes[i]
                var peak: Float = 0
                for k in 0..<n {
                    let s = inPtr[k]
                    if abs(s) > peak { peak = abs(s) }
                    outPtr[k] += s * g
                }
                inPeaks[i] = peak
            }
        }

        // Hard limiter on the final mix — the universal safety net.
        let ceil = limiterCeiling
        for i in 0..<outCount {
            let v = outPtr[i]
            if v > ceil { outPtr[i] = ceil } else if v < -ceil { outPtr[i] = -ceil }
        }

        // Zero any extra output buffers.
        for j in 1..<outs.count { if let d = outs[j].mData { memset(d, 0, Int(outs[j].mDataByteSize)) } }
    }

    // MARK: - Teardown

    private func teardown() throws {
        // CRITICAL: restore each tapped app's own audio FIRST, while its tap is
        // still live inside the *running* aggregate. A tap created with
        // `.mutedWhenTapped` mutes the app's own output; macOS only applies an
        // un-mute to the live audio stream while the tap is still being driven.
        // Destroying the tap (or un-muting it after the aggregate is stopped)
        // leaves the app stuck SILENT — which is what happened when toggling
        // Active off. So we flip every tap to unmuted, let the HAL apply it to
        // the live stream, and only then tear everything down.
        if #available(macOS 14.2, *), isStarted, !tapIDs.isEmpty {
            for tap in tapIDs { setTapUnmuted(tap) }
            usleep(80_000)   // ~80ms for the HAL to restore the live streams
        }

        if isStarted, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            isStarted = false
        }
        if let proc = ioProcID, aggregateDeviceID != kAudioObjectUnknown {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, proc)
        }
        ioProcID = nil
        if aggregateDeviceID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if #available(macOS 14.2, *) {
            for tap in tapIDs { AudioHardwareDestroyProcessTap(tap) }
        }
        tapIDs = []
    }

    /// Flip a live tap's mute behavior to `.unmuted` so the tapped app's own
    /// output is restored. Must be done while the tap is still being driven by
    /// the running aggregate (see teardown()).
    @available(macOS 14.2, *)
    private func setTapUnmuted(_ tap: AudioObjectID) {
        var address = CoreAudioProperty.address(kAudioTapPropertyDescription)
        var size = UInt32(MemoryLayout<UnsafeRawPointer?>.size)
        var current: Unmanaged<CATapDescription>? = nil
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &current) == noErr,
              let desc = current?.takeRetainedValue() else { return }
        desc.muteBehavior = .unmuted
        var ref: Unmanaged<CATapDescription>? = Unmanaged.passUnretained(desc)
        _ = AudioObjectSetPropertyData(tap, &address, 0, nil, size, &ref)
    }

    // MARK: - Un-duck (same mechanism as the proven engine)

    private typealias DuckFn = @convention(c)
        (AudioObjectID, Float32, UnsafePointer<AudioTimeStamp>?, Float32) -> OSStatus

    /// Resolved ONCE — the un-duck loop runs twice a second, so re-doing
    /// dlopen/dlsym/dlclose every tick was pure wasted CPU and wakeups.
    private static let audioDeviceDuck: DuckFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "AudioDeviceDuck") else { return nil }
        return unsafeBitCast(sym, to: DuckFn.self)
    }()

    private func applyUnduck() {
        if let duck = Self.audioDeviceDuck {
            if aggregateDeviceID != kAudioObjectUnknown { _ = duck(aggregateDeviceID, 1.0, nil, 0) }
            if outputDeviceID != kAudioObjectUnknown { _ = duck(outputDeviceID, 1.0, nil, 0) }
        }
        writeDuckProperty(outputDeviceID)
        writeDuckProperty(aggregateDeviceID)
    }

    private func writeDuckProperty(_ deviceID: AudioObjectID) {
        guard deviceID != kAudioObjectUnknown else { return }
        for scope in [kAudioDevicePropertyScopeOutput, kAudioObjectPropertyScopeGlobal] {
            var address = CoreAudioProperty.address(FourCC.make("duck"), scope: scope)
            guard AudioObjectHasProperty(deviceID, &address) else { continue }
            var settable: DarwinBoolean = false
            guard AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue else { continue }
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
