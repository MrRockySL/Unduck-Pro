import DuckAudioCore
import Foundation

@main
struct DuckAudioPhase0 {
    static func main() async {
        do {
            let configuration = try parseArguments(CommandLine.arguments)
            try await Phase0Diagnostic(configuration: configuration).run()
        } catch {
            fputs("duck-audio-phase0: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func parseArguments(_ arguments: [String]) throws -> Phase0Configuration {
        var duration: Double = 30
        var interval: Double = 1
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

            case "--help", "-h":
                printUsage()
                Foundation.exit(0)

            default:
                throw ArgumentError.invalidValue("unknown argument: \(arguments[index])")
            }

            index += 1
        }

        return Phase0Configuration(durationSeconds: duration, intervalSeconds: interval)
    }

    private static func printUsage() {
        print("""
        usage: duck-audio-phase0 [--duration seconds] [--interval seconds]

        Measurement-only diagnostic. It reads Core Audio device/process state and
        never creates taps, aggregate devices, IOProcs, or speaker output.
        """)
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
