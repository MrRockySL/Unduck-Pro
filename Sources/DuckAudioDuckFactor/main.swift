import Darwin
import DuckAudioCore
import Foundation

@main
struct DuckAudioDuckFactor {
    static func main() async {
        do {
            let options = try parseArguments(CommandLine.arguments)
            try await run(options: options)
        } catch {
            fputs("duck-audio-duckfactor: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run(options: Options) async throws {
        print("Duck Audio duck factor")
        print("Mode: measurement-only two-pass tap; output buffers are forced to silence")
        print("Pass 1 uses tapMode=unmuted to measure the ordinary ducked output path.")
        print("Pass 2 uses tapMode=muted-when-tapped to measure the full captured media path; YouTube/media will be silent during this pass.")
        print("Start a call and play steady media before the first pass starts.")

        let unmuted = try await collect(
            label: "unmuted",
            captureMode: .unmuted,
            options: options
        )

        if options.settleSeconds > 0 {
            print("Settling for \(format(options.settleSeconds)) seconds before muted capture...")
            try await Task.sleep(nanoseconds: UInt64(options.settleSeconds * 1_000_000_000))
        }

        let muted = try await collect(
            label: "muted-when-tapped",
            captureMode: .mutedWhenTapped,
            options: options
        )

        print("")
        print("Duck factor summary")
        print("unmutedMaxRawPeak=\(format(unmuted.maxRawPeak)) mutedMaxRawPeak=\(format(muted.maxRawPeak))")

        guard unmuted.maxRawPeak > 0, muted.maxRawPeak > 0 else {
            print("Result: insufficient non-silent audio. Keep the call active, play steadier media, and run again.")
            return
        }

        let ratio = muted.maxRawPeak / unmuted.maxRawPeak
        let compensationDB = 20 * log10(Double(ratio))
        let ordinaryPathDeltaDB = -compensationDB
        print("duckRatio=full/unmuted=\(format(ratio))")
        print("ordinaryPathDelta=\(String(format: "%.2f", ordinaryPathDeltaDB)) dB neededCompensation=\(String(format: "%.2f", compensationDB)) dB")
        print("Interpretation: a large ratio confirms heavy call ducking. Speaker replay must be tested first at unity gain, then any boost must stay behind call gating, headroom control, and the hard limiter.")
    }

    private static func collect(
        label: String,
        captureMode: TapCaptureMode,
        options: Options
    ) async throws -> TapMeterSnapshot {
        print("")
        print("Starting pass: \(label)")

        let configuration = TapMeterConfiguration(
            durationSeconds: options.durationSeconds,
            intervalSeconds: options.intervalSeconds,
            captureMode: captureMode,
            simulatedGain: 10,
            maxGain: 10,
            limiterCeiling: 0.90,
            autoGain: true,
            headroomRatio: 0.98
        )
        let engine = TapMeterEngine(configuration: configuration)
        try engine.start()

        do {
            let iterations = max(1, Int((options.durationSeconds / options.intervalSeconds).rounded(.up)))
            for iteration in 0..<iterations {
                let timestamp = ISO8601DateFormatter().string(from: Date())
                let snapshot = engine.snapshot()
                let limitedPercent = snapshot.sampleCount > 0
                    ? (Double(snapshot.limitedSampleCount) / Double(snapshot.sampleCount)) * 100
                    : 0
                print("[\(timestamp)] \(label) sample \(iteration + 1)/\(iterations) callbacks=\(snapshot.callbackCount) rawPeak=\(format(snapshot.peak)) maxRawPeak=\(format(snapshot.maxRawPeak)) simPeak=\(format(snapshot.simulatedPeak)) limited=\(snapshot.limitedSampleCount)/\(snapshot.sampleCount) (\(String(format: "%.2f", limitedPercent))%)")

                if iteration < iterations - 1 {
                    try await Task.sleep(nanoseconds: UInt64(options.intervalSeconds * 1_000_000_000))
                }
            }

            let finalSnapshot = engine.snapshot()
            try engine.stop()
            return finalSnapshot
        } catch {
            try? engine.stop()
            throw error
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> Options {
        var duration: Double = 12
        var interval: Double = 1
        var settle: Double = 2
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0 else {
                    throw ArgumentError.invalidValue("--duration expects a positive number of seconds per pass")
                }
                duration = parsed

            case "--interval":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed > 0 else {
                    throw ArgumentError.invalidValue("--interval expects a positive number of seconds")
                }
                interval = parsed

            case "--settle":
                index += 1
                guard index < arguments.count, let parsed = Double(arguments[index]), parsed >= 0 else {
                    throw ArgumentError.invalidValue("--settle expects a non-negative number of seconds")
                }
                settle = parsed

            case "--help", "-h":
                printUsage()
                Foundation.exit(0)

            default:
                throw ArgumentError.invalidValue("unknown argument: \(arguments[index])")
            }

            index += 1
        }

        return Options(
            durationSeconds: duration,
            intervalSeconds: interval,
            settleSeconds: settle
        )
    }

    private static func printUsage() {
        print("""
        usage: duck-audio-duckfactor [--duration seconds] [--interval seconds] [--settle seconds]

        Measurement-only two-pass harness. It measures unmuted capture, then
        muted-when-tapped capture, and reports the observed ducking ratio. It
        writes silence to output buffers and does not replay or amplify audio.
        """)
    }

    private static func format(_ value: Float) -> String {
        String(format: "%.6f", value)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}

private struct Options: Equatable {
    let durationSeconds: Double
    let intervalSeconds: Double
    let settleSeconds: Double
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
