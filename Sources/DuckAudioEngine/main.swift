import DuckAudioCore
import Foundation

@main
struct DuckAudioEngine {
    static func main() async {
        do {
            let options = try parseArguments(CommandLine.arguments)
            try await run(options: options)
        } catch {
            fputs("duck-audio-engine: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(options: Options) async throws {
        print("Duck Audio Engine")
        print("═══════════════════════════════════════════════════════")

        if options.dryRun {
            print("Mode: DRY RUN — engine will start but gain is locked to 1x")
            print("       Use this to verify the tap + aggregate work before enabling boost")
        } else {
            print("Mode: LIVE — gain will be applied when a call is detected")
        }

        let effectiveCallGain: Float = options.dryRun ? 1 : options.callGain
        print("Call gain: \(format(effectiveCallGain))x (\(String(format: "%.1f", 20 * log10(Double(effectiveCallGain)))) dB)")
        print("Max gain: \(format(options.maxGain))x  Limiter ceiling: \(format(options.ceiling))")
        print("Auto-headroom: \(options.autoHeadroom)")
        print("")

        // Set up CallWatcher
        let callWatcher = CallWatcher(pollInterval: 1.0)

        // Set up TapEngine
        let config = TapEngineConfiguration(
            callGain: effectiveCallGain,
            maxGain: options.maxGain,
            limiterCeiling: options.ceiling,
            gainRisePerBuffer: 0.25,
            gainFallPerBuffer: options.maxGain,
            autoHeadroom: options.autoHeadroom,
            headroomRatio: 0.98
        )
        let engine = TapEngine(configuration: config, callWatcher: callWatcher)

        // Wire up CallWatcher → TapEngine
        let coordinator = EngineCoordinator(engine: engine)
        callWatcher.delegate = coordinator

        // Start
        callWatcher.start()
        print("CallWatcher started (polling every 1s)")

        let initialState = callWatcher.currentState
        print("Initial call state: \(describeCallState(initialState))")

        try engine.start()
        print("Engine started — tap + aggregate + IOProc active")

        if options.dryRun {
            print("")
            print("⚠️  DRY RUN: audio is being captured and replayed at unity gain (1x).")
            print("   If you hear your media during a call, the replay path works!")
            print("   Press Ctrl-C to stop.")
        } else {
            print("")
            print("🎵 Engine running. Media will stay loud during calls.")
            print("   Press Ctrl-C to stop.")
        }
        print("───────────────────────────────────────────────────────")

        // Periodic status reporting
        let statusInterval = options.statusInterval
        let statusTask = Task {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: UInt64(statusInterval * 1_000_000_000))
                let snap = engine.snapshot()
                let state = callWatcher.currentState
                let limitedPercent = snap.totalSampleCount > 0
                    ? (Double(snap.limitedSampleCount) / Double(snap.totalSampleCount)) * 100
                    : 0
                let timestamp = ISO8601DateFormatter().string(from: Date())
                print("[\(timestamp)] \(describeCallState(state)) | gain=\(format(snap.appliedGain)) inPeak=\(format(snap.inputPeak)) outPeak=\(format(snap.outputPeak)) callbacks=\(snap.callbackCount) limited=\(String(format: "%.2f", limitedPercent))%")
            }
        }

        // Wait for Ctrl-C using a continuation-safe pattern
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
            signal(SIGINT, SIG_IGN)
            signal(SIGTERM, SIG_IGN)
            let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

            var resumed = false
            let resume = {
                guard !resumed else { return }
                resumed = true
                signalSource.cancel()
                termSource.cancel()
                continuation.resume()
            }

            signalSource.setEventHandler { resume() }
            termSource.setEventHandler { resume() }
            signalSource.resume()
            termSource.resume()
        }
        statusTask.cancel()

        print("")
        print("───────────────────────────────────────────────────────")
        print("Stopping engine...")

        callWatcher.stop()
        do {
            try engine.stop()
            print("Engine stopped cleanly.")
        } catch {
            fputs("Engine stop error: \(error)\n", stderr)
        }

        let finalSnap = engine.snapshot()
        print("Final: callbacks=\(finalSnap.callbackCount) frames=\(finalSnap.totalFrames) totalLimited=\(finalSnap.limitedSampleCount)/\(finalSnap.totalSampleCount)")
    }

    private static func describeCallState(_ state: CallState) -> String {
        switch state {
        case .noCall:
            return "no-call"
        case .inCall(let processes):
            let names = processes.map(\.matchedName).joined(separator: ", ")
            return "IN-CALL [\(names)]"
        }
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.4f", value)
    }

    // MARK: - Argument parsing

    private static func parseArguments(_ arguments: [String]) throws -> Options {
        var callGain: Float = 33  // ~30 dB, slightly above measured 32.69
        var maxGain: Float = 40
        var ceiling: Float = 0.90
        var autoHeadroom = true
        var dryRun = false
        var statusInterval: Double = 2
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--call-gain":
                index += 1
                guard index < arguments.count, let parsed = Float(arguments[index]), parsed >= 1 else {
                    throw ArgumentError.invalidValue("--call-gain expects a number >= 1")
                }
                callGain = parsed

            case "--max-gain":
                index += 1
                guard index < arguments.count, let parsed = Float(arguments[index]), parsed >= 1 else {
                    throw ArgumentError.invalidValue("--max-gain expects a number >= 1")
                }
                maxGain = parsed

            case "--ceiling":
                index += 1
                guard index < arguments.count, let parsed = Float(arguments[index]), parsed > 0, parsed <= 1 else {
                    throw ArgumentError.invalidValue("--ceiling expects a number > 0 and <= 1")
                }
                ceiling = parsed

            case "--no-auto-headroom":
                autoHeadroom = false

            case "--dry-run":
                dryRun = true

            case "--status-interval":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0 else {
                    throw ArgumentError.invalidValue("--status-interval expects a positive number of seconds")
                }
                statusInterval = parsed

            case "--help", "-h":
                printUsage()
                Foundation.exit(0)

            default:
                throw ArgumentError.invalidValue("unknown argument: \(arguments[index])")
            }
            index += 1
        }

        return Options(
            callGain: callGain,
            maxGain: maxGain,
            ceiling: ceiling,
            autoHeadroom: autoHeadroom,
            dryRun: dryRun,
            statusInterval: statusInterval
        )
    }

    private static func printUsage() {
        print("""
        usage: duck-audio-engine [options]

        Duck Audio production engine. Keeps media loud during calls.

        Options:
          --call-gain <factor>     Gain during calls (default: 33, ~30 dB)
          --max-gain <factor>      Maximum gain cap (default: 40)
          --ceiling <0...1>        Hard limiter ceiling (default: 0.90)
          --no-auto-headroom       Disable auto-headroom for hot buffers
          --dry-run                Lock gain to 1x (test that replay works first)
          --status-interval <sec>  Seconds between status prints (default: 2)
          --help, -h               Show this help
        """)
    }
}

/// Coordinates between CallWatcher and TapEngine.
private final class EngineCoordinator: CallWatcherDelegate, @unchecked Sendable {
    private let engine: TapEngine

    init(engine: TapEngine) {
        self.engine = engine
    }

    func callWatcher(_ watcher: CallWatcher, didChangeState newState: CallState, exclusionSetChanged: Bool) {
        // Always update the gain
        engine.updateCallState(newState)

        // Rebuild tap if the exclusion set changed (new call process appeared/disappeared)
        if exclusionSetChanged {
            do {
                try engine.rebuildTap(for: newState)
                let desc: String
                switch newState {
                case .noCall:
                    desc = "no-call"
                case .inCall(let processes):
                    desc = "IN-CALL [\(processes.map(\.matchedName).joined(separator: ", "))]"
                }
                print("[CallWatcher] State changed → \(desc); tap rebuilt with updated exclusions")
            } catch {
                fputs("[CallWatcher] Tap rebuild failed: \(error)\n", stderr)
            }
        }
    }
}

private struct Options {
    let callGain: Float
    let maxGain: Float
    let ceiling: Float
    let autoHeadroom: Bool
    let dryRun: Bool
    let statusInterval: Double
}

private enum ArgumentError: Error, CustomStringConvertible {
    case invalidValue(String)

    var description: String {
        switch self {
        case .invalidValue(let message):
            return message
        }
    }
}
