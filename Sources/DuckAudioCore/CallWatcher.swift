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

    /// The set of Core Audio object IDs that should be excluded from the tap.
    public var excludedObjectIDs: Set<AudioObjectID> {
        switch self {
        case .noCall:
            return []
        case .inCall(let processes):
            return Set(processes.map(\.objectID))
        }
    }
}

/// Minimal info about a detected call process.
public struct CallProcessInfo: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t?
    public let bundleID: String?
    public let matchedName: String

    public init(objectID: AudioObjectID, pid: pid_t?, bundleID: String?, matchedName: String) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.matchedName = matchedName
    }
}

/// Delegate protocol for `CallWatcher` state changes.
public protocol CallWatcherDelegate: AnyObject, Sendable {
    /// Called on a background queue when the call state changes.
    /// `exclusionSetChanged` is true when the set of excluded process IDs
    /// differs from the previous state — this signals the tap needs rebuilding.
    func callWatcher(_ watcher: CallWatcher, didChangeState newState: CallState, exclusionSetChanged: Bool)
}

/// Polls Core Audio's process list to detect active voice calls.
///
/// Runs a timer on a background dispatch queue at a configurable interval
/// (default 1 second). When the call state changes, it notifies its delegate.
public final class CallWatcher: @unchecked Sendable {
    public let pollInterval: TimeInterval
    public weak var delegate: CallWatcherDelegate?

    private let lock = NSLock()
    private var _currentState: CallState = .noCall
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
        let newState = detectCallState()

        let (changed, exclusionSetChanged) = lock.withLock { () -> (Bool, Bool) in
            let oldState = _currentState
            let newExcludedIDs = newState.excludedObjectIDs

            let stateChanged = oldState != newState
            let exclusionChanged = newExcludedIDs != _previousExcludedIDs

            if stateChanged || exclusionChanged {
                _currentState = newState
                _previousExcludedIDs = newExcludedIDs
            }

            return (stateChanged, exclusionChanged)
        }

        if changed || exclusionSetChanged {
            delegate?.callWatcher(self, didChangeState: newState, exclusionSetChanged: exclusionSetChanged)
        }
    }

    private func detectCallState() -> CallState {
        guard let callProcesses = try? AudioProcessProbe.inputRunningCallProcesses(),
              !callProcesses.isEmpty else {
            return .noCall
        }

        let infos = callProcesses.map { process in
            CallProcessInfo(
                objectID: process.objectID,
                pid: process.pid,
                bundleID: process.bundleID,
                matchedName: process.callMatch?.name ?? "unknown"
            )
        }

        return .inCall(processes: infos)
    }
}
