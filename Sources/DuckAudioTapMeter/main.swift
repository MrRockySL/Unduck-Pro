import DuckAudioCore
import Foundation

@main
struct DuckAudioTapMeter {
    static func main() async {
        do {
            let configuration = try parseArguments(CommandLine.arguments)
            try await run(configuration: configuration)
        } catch {
            fputs("duck-audio-tapmeter: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(configuration: TapMeterConfiguration) async throws {
        print("Duck Audio tap meter")
        print("Mode: measurement-only process tap; output buffers are forced to silence")
        print("Capture: tapMode=\(configuration.captureMode.rawValue)")
        print("Simulation: mode=\(configuration.autoGain ? "auto-headroom" : "fixed") requestedGain=\(format(configuration.simulatedGain)) maxGain=\(format(configuration.maxGain)) limiterCeiling=\(format(configuration.limiterCeiling))")
        print("Start a call and play media. Raw levels should move, sim levels should stay at or below the limiter ceiling.")

        let engine = TapMeterEngine(configuration: configuration)
        try engine.start()
        defer {
            do {
                try engine.stop()
            } catch {
                fputs("duck-audio-tapmeter cleanup: \(error)\n", stderr)
            }
        }

        let iterations = max(1, Int((configuration.durationSeconds / configuration.intervalSeconds).rounded(.up)))
        for iteration in 0..<iterations {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let snapshot = engine.snapshot()
            let limitedPercent = snapshot.sampleCount > 0
                ? (Double(snapshot.limitedSampleCount) / Double(snapshot.sampleCount)) * 100
                : 0
            print("[\(timestamp)] sample \(iteration + 1)/\(iterations) callbacks=\(snapshot.callbackCount) frames=\(snapshot.totalFrames) lastFrames=\(snapshot.lastFrameCount) rawPeak=\(format(snapshot.peak)) rawRMS=\(format(snapshot.rms)) request=\(format(snapshot.requestedGain)) gain=\(format(snapshot.simulatedGain)) simPeak=\(format(snapshot.simulatedPeak)) simRMS=\(format(snapshot.simulatedRMS)) limited=\(snapshot.limitedSampleCount)/\(snapshot.sampleCount) (\(String(format: "%.2f", limitedPercent))%)")

            if iteration < iterations - 1 {
                try await Task.sleep(nanoseconds: UInt64(configuration.intervalSeconds * 1_000_000_000))
            }
        }

        let finalSnapshot = engine.snapshot()
        let totalLimitedPercent = finalSnapshot.totalSampleCount > 0
            ? (Double(finalSnapshot.totalLimitedSampleCount) / Double(finalSnapshot.totalSampleCount)) * 100
            : 0
        print("Summary: callbacks=\(finalSnapshot.callbackCount) frames=\(finalSnapshot.totalFrames) maxRawPeak=\(format(finalSnapshot.maxRawPeak)) maxSimPeak=\(format(finalSnapshot.maxSimulatedPeak)) totalLimited=\(finalSnapshot.totalLimitedSampleCount)/\(finalSnapshot.totalSampleCount) (\(String(format: "%.4f", totalLimitedPercent))%)")
        print("Tap meter complete.")
    }

    private static func parseArguments(_ arguments: [String]) throws -> TapMeterConfiguration {
        var duration: Double = 30
        var interval: Double = 1
        var captureMode = TapCaptureMode.mutedWhenTapped
        var gain: Float = 10
        var maxGain: Float = 10
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

            case "--tap-mode":
                index += 1
                guard index < arguments.count, let parsed = TapCaptureMode(rawValue: arguments[index]) else {
                    throw ArgumentError.invalidValue("--tap-mode expects muted-when-tapped, unmuted, or muted")
                }
                captureMode = parsed

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

        return TapMeterConfiguration(
            durationSeconds: duration,
            intervalSeconds: interval,
            captureMode: captureMode,
            simulatedGain: gain,
            maxGain: maxGain,
            limiterCeiling: ceiling,
            autoGain: autoGain,
            headroomRatio: headroomRatio
        )
    }

    private static func printUsage() {
        print("""
        usage: duck-audio-tapmeter [--duration seconds] [--interval seconds] [--tap-mode muted-when-tapped|unmuted|muted] [--gain factor] [--max-gain factor] [--ceiling 0...1] [--auto-gain] [--headroom 0...1]

        Measurement-only process tap harness. It meters captured audio, simulates
        SafeGain + hard limiter, and writes silence to output buffers. It does
        not replay or amplify speaker audio.
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
