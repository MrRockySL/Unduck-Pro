import CoreAudio
import Dispatch
import Foundation

/// The current call state observed by `CallWatcher`.
public enum CallState: Equatable, Sendable {
    /// No known call process is running input.
    case noCall
    /// One or more known call processes are running input.
    case inCall(processes: [CallProcessInfo])

    public var isInCall: Bool {
        if case .inCall = self { return true }
        return false
    }

    /// The set of Core Audio object IDs that belong to live call processes.
    /// The audio engine decides whether those processes are excluded or tapped.
    public var excludedObjectIDs: Set<AudioObjectID> {
        switch self {
        case .noCall:
            return []
        case .inCall(let processes):
            return Set(processes.map(\.objectID))
        }
    }

    /// Logical call-app families currently using input. Helpers that only play
    /// the remote caller can be associated with the same mixer row through this.
    public var activeFamilies: Set<String> {
        switch self {
        case .noCall:
            return []
        case .inCall(let processes):
            return Set(processes.map(\.matchedFamily))
        }
    }
}

/// One lightweight Core Audio process snapshot used for background engine
/// maintenance. Keeping this separate from the UI lets the mixer panel sleep
/// without letting the tap set become stale.
public struct AudioActivitySnapshot: Equatable, Sendable {
    public let callState: CallState
    public let outputObjectIDs: Set<AudioObjectID>
    public let outputDeviceID: AudioObjectID

    public init(
        callState: CallState,
        outputObjectIDs: Set<AudioObjectID>,
        outputDeviceID: AudioObjectID = kAudioObjectUnknown
    ) {
        self.callState = callState
        self.outputObjectIDs = outputObjectIDs
        self.outputDeviceID = outputDeviceID
    }
}

/// Minimal info about a detected call process.
public struct CallProcessInfo: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t?
    public let bundleID: String?
    public let matchedName: String
    public let matchedFamily: String

    public init(
        objectID: AudioObjectID,
        pid: pid_t?,
        bundleID: String?,
        matchedName: String,
        matchedFamily: String? = nil
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.matchedName = matchedName
        self.matchedFamily = matchedFamily ?? matchedName.lowercased()
    }
}

/// Delegate protocol for `CallWatcher` state changes.
public protocol CallWatcherDelegate: AnyObject, Sendable {
    /// Called on a background queue when the call state or output-process set changes.
    /// `exclusionSetChanged` is true when the set of excluded process IDs
    /// differs from the previous state — this signals the tap needs rebuilding.
    func callWatcher(_ watcher: CallWatcher, didChangeState newState: CallState, exclusionSetChanged: Bool)
}

/// Polls Core Audio's process list to detect active voice calls and output apps.
///
/// Runs a timer on a background dispatch queue at a configurable interval
/// (default 1 second). A single process scan drives both call detection and
/// background tap maintenance, avoiding a second expensive polling loop.
public final class CallWatcher: @unchecked Sendable {
    public let pollInterval: TimeInterval
    public weak var delegate: CallWatcherDelegate?

    private let lock = NSLock()
    private var _currentState: CallState = .noCall
    private var _currentOutputObjectIDs: Set<AudioObjectID> = []
    private var _currentOutputDeviceID: AudioObjectID = kAudioObjectUnknown
    private var _previousExcludedIDs: Set<AudioObjectID> = []
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dev.mrrockysl.duckaudio.callwatcher", qos: .utility)

    public init(pollInterval: TimeInterval = 1.0) {
        precondition(pollInterval > 0)
        self.pollInterval = pollInterval
    }

    deinit {
        stop()
    }

    /// The last observed call state. Thread-safe.
    public var currentState: CallState {
        lock.withLock { _currentState }
    }

    /// Output-producing process IDs from the last successful scan. Thread-safe.
    public var currentOutputObjectIDs: Set<AudioObjectID> {
        lock.withLock { _currentOutputObjectIDs }
    }

    /// Default hardware output from the last successful scan. Thread-safe.
    public var currentOutputDeviceID: AudioObjectID {
        lock.withLock { _currentOutputDeviceID }
    }

    /// Start polling. Performs an immediate first poll.
    public func start() {
        stop()

        // Immediate first poll
        poll()

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(
            deadline: .now() + pollInterval,
            repeating: pollInterval,
            leeway: .milliseconds(100)
        )
        source.setEventHandler { [weak self] in
            self?.poll()
        }
        source.resume()
        timer = source
    }

    /// Stop polling.
    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Force a single poll right now (useful for tests and after tap rebuild).
    public func pollNow() {
        poll()
    }

    // MARK: - Private

    private func poll() {
        // A failed Core Audio read must not look like every app and call stopped.
        // Preserve the last good snapshot and try again on the next timer tick.
        guard let processes = try? AudioProcessProbe.allProcesses() else { return }
        let selfObjectID = (try? AudioProcessProbe.currentProcessObjectID()) ?? kAudioObjectUnknown
        let previousDeviceID = lock.withLock { _currentOutputDeviceID }
        let outputDeviceID = (try? AudioDeviceProbe.defaultOutputDeviceID()) ?? previousDeviceID
        let snapshot = Self.makeSnapshot(
            processes: processes,
            selfObjectID: selfObjectID,
            outputDeviceID: outputDeviceID
        )
        let newState = snapshot.callState

        let (changed, exclusionSetChanged, outputsChanged, deviceChanged) = lock.withLock { () -> (Bool, Bool, Bool, Bool) in
            let oldState = _currentState
            let newExcludedIDs = newState.excludedObjectIDs

            let stateChanged = oldState != newState
            let exclusionChanged = newExcludedIDs != _previousExcludedIDs
            let outputChanged = snapshot.outputObjectIDs != _currentOutputObjectIDs
            let outputDeviceChanged = snapshot.outputDeviceID != _currentOutputDeviceID

            if stateChanged || exclusionChanged || outputChanged || outputDeviceChanged {
                _currentState = newState
                _previousExcludedIDs = newExcludedIDs
                _currentOutputObjectIDs = snapshot.outputObjectIDs
                _currentOutputDeviceID = snapshot.outputDeviceID
            }

            return (stateChanged, exclusionChanged, outputChanged, outputDeviceChanged)
        }

        if changed || exclusionSetChanged || outputsChanged || deviceChanged {
            delegate?.callWatcher(self, didChangeState: newState, exclusionSetChanged: exclusionSetChanged)
        }
    }

    /// Convert one Core Audio process scan into the two sets the engine needs.
    /// Public so the deterministic filtering can be covered by the self-test.
    public static func makeSnapshot(
        processes: [AudioProcessInfo],
        selfObjectID: AudioObjectID,
        outputDeviceID: AudioObjectID = kAudioObjectUnknown
    ) -> AudioActivitySnapshot {
        let callProcesses = processes.filter { $0.isRunningInput && $0.callMatch != nil }
        let infos = callProcesses.map { process in
            CallProcessInfo(
                objectID: process.objectID,
                pid: process.pid,
                bundleID: process.bundleID,
                matchedName: process.callMatch?.name ?? "unknown",
                matchedFamily: process.callMatch?.family ?? "unknown"
            )
        }
        let callState: CallState = infos.isEmpty ? .noCall : .inCall(processes: infos)
        let outputs = Set(processes.compactMap { process -> AudioObjectID? in
            guard process.isRunningOutput,
                  process.objectID != selfObjectID,
                  process.processName != nil || process.bundleID != nil else { return nil }
            return process.objectID
        })
        return AudioActivitySnapshot(
            callState: callState,
            outputObjectIDs: outputs,
            outputDeviceID: outputDeviceID
        )
    }
}
