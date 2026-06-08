import DuckAudioCore
import Foundation

@main
struct DuckAudioReplayProbe {
    static func main() async {
        do {
            let configuration = try parseArguments(CommandLine.arguments)
            try await run(configuration: configuration)
        } catch {
            fputs("duck-audio-replay-probe: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(configuration: ReplayProbeConfiguration) async throws {
        print("Duck Audio replay probe")
        if configuration.speakerOutputEnabled {
            print("Mode: LOW-VOLUME SPEAKER OUTPUT; muted tap -> SafeGain -> hard limiter -> default speakers")
            print("Safety: requires active call, --low-volume-confirmed, gain=1, maxGain=1, limiterCeiling=\(format(configuration.limiterCeiling))")
        } else {
            print("Mode: dry-run measurement only; output buffers are forced to silence")
        }
        print("Capture: tapMode=muted-when-tapped")
        print("Gain: requested=\(format(configuration.simulatedGain)) max=\(format(configuration.maxGain)) autoGain=\(configuration.autoGain)")

        let engine = ReplayProbeEngine(configuration: configuration)
        try engine.start()
        defer {
            do {
                try engine.stop()
            } catch {
                fputs("duck-audio-replay-probe cleanup: \(error)\n", stderr)
            }
        }

        let iterations = max(1, Int((configuration.durationSeconds / configuration.intervalSeconds).rounded(.up)))
        for iteration in 0..<iterations {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let snapshot = engine.snapshot()
            let limitedPercent = snapshot.sampleCount > 0
                ? (Double(snapshot.limitedSampleCount) / Double(snapshot.sampleCount)) * 100
                : 0
            print("[\(timestamp)] sample \(iteration + 1)/\(iterations) callbacks=\(snapshot.callbackCount) frames=\(snapshot.totalFrames) rawPeak=\(format(snapshot.peak)) gain=\(format(snapshot.simulatedGain)) outPeak=\(format(snapshot.simulatedPeak)) limited=\(snapshot.limitedSampleCount)/\(snapshot.sampleCount) (\(String(format: "%.2f", limitedPercent))%)")

            if iteration < iterations - 1 {
                try await Task.sleep(nanoseconds: UInt64(configuration.intervalSeconds * 1_000_000_000))
            }
        }

        let finalSnapshot = engine.snapshot()
        let totalLimitedPercent = finalSnapshot.totalSampleCount > 0
            ? (Double(finalSnapshot.totalLimitedSampleCount) / Double(finalSnapshot.totalSampleCount)) * 100
            : 0
        print("Summary: callbacks=\(finalSnapshot.callbackCount) frames=\(finalSnapshot.totalFrames) maxRawPeak=\(format(finalSnapshot.maxRawPeak)) maxOutPeak=\(format(finalSnapshot.maxSimulatedPeak)) totalLimited=\(finalSnapshot.totalLimitedSampleCount)/\(finalSnapshot.totalSampleCount) (\(String(format: "%.4f", totalLimitedPercent))%)")
        print("Replay probe complete.")
    }

    private static func parseArguments(_ arguments: [String]) throws -> ReplayProbeConfiguration {
        var duration: Double = 10
        var interval: Double = 1
        var speakerOutputEnabled = false
        var lowVolumeConfirmed = false
        var gain: Float = 1
        var maxGain: Float = 1
        var ceiling: Float = 0.90
        var autoGain = false
        var headroomRatio: Float = 0.98
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0 else {
                    throw ArgumentError.invalidValue("--duration expects a positive number of seconds")
                }
                duration = parsed

            case "--interval":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0 else {
                    throw ArgumentError.invalidValue("--interval expects a positive number of seconds")
                }
                interval = parsed

            case "--enable-speaker-output":
                speakerOutputEnabled = true

            case "--low-volume-confirmed":
                lowVolumeConfirmed = true

            case "--gain":
                index += 1
                guard index < arguments.count, let parsed = Float(arguments[index]), parsed >= 1 else {
                    throw ArgumentError.invalidValue("--gain expects a number >= 1")
                }
                gain = parsed

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

            case "--auto-gain":
                autoGain = true

            case "--headroom":
                index += 1
                guard index < arguments.count, let parsed = Float(arguments[index]), parsed > 0, parsed <= 1 else {
                    throw ArgumentError.invalidValue("--headroom expects a number > 0 and <= 1")
                }
                headroomRatio = parsed

            case "--help", "-h":
                printUsage()
                Foundation.exit(0)

            default:
                throw ArgumentError.invalidValue("unknown argument: \(arguments[index])")
            }

            index += 1
        }

        return ReplayProbeConfiguration(
            durationSeconds: duration,
            intervalSeconds: interval,
            speakerOutputEnabled: speakerOutputEnabled,
            lowVolumeConfirmed: lowVolumeConfirmed,
            simulatedGain: gain,
            maxGain: maxGain,
            limiterCeiling: ceiling,
            autoGain: autoGain,
            headroomRatio: headroomRatio
        )
    }

    private static func printUsage() {
        print("""
        usage: duck-audio-replay-probe [--duration seconds] [--interval seconds] [--enable-speaker-output --low-volume-confirmed] [--gain 1] [--max-gain 1] [--ceiling 0...1]

        Guarded replay probe. By default it is measurement-only and writes
        silence to output buffers. Speaker output requires explicit flags, an
        active call, low system volume, and unity gain only.
        """)
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.6f", value)
    }
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
