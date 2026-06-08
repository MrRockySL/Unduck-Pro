import CoreAudio
import Foundation

public struct Phase0Configuration: Equatable, Sendable {
    public let durationSeconds: Double
    public let intervalSeconds: Double

    public init(durationSeconds: Double = 30, intervalSeconds: Double = 1) {
        precondition(durationSeconds > 0)
        precondition(intervalSeconds > 0)
        self.durationSeconds = durationSeconds
        self.intervalSeconds = intervalSeconds
    }
}

public struct Phase0Diagnostic: Sendable {
    public let configuration: Phase0Configuration

    public init(configuration: Phase0Configuration) {
        self.configuration = configuration
    }

    public func run() async throws {
        guard #available(macOS 14.2, *) else {
            throw Phase0Error.unsupportedOS
        }

        let outputDevice = try AudioDeviceProbe.defaultOutputDeviceInfo()
        let outputName = outputDevice.name ?? "unknown"
        let outputUID = outputDevice.uid ?? "unknown"
        let sampleRate = outputDevice.nominalSampleRate.map { String($0) } ?? "unknown"

        print("Duck Audio Phase 0 diagnostic")
        print("Mode: measurement/logging only; no taps, no aggregate device, no speaker output")
        print("Default output: id=\(outputDevice.id) name=\(outputName) uid=\(outputUID) sampleRate=\(sampleRate)")

        let selfObject = try? AudioProcessProbe.currentProcessObjectID()
        if let selfObject {
            print("Self process Core Audio object: \(selfObject) (must be excluded from future taps)")
        } else {
            print("Self process Core Audio object: unavailable until this process touches Core Audio")
        }

        let iterations = max(1, Int((configuration.durationSeconds / configuration.intervalSeconds).rounded(.up)))
        for iteration in 0..<iterations {
            let timestamp = ISO8601DateFormatter().string(from: Date())
            let snapshots = try DuckPropertyReader.readAllScopes(deviceID: outputDevice.id)
            let inputProcesses = try AudioProcessProbe.inputRunningProcesses()
            let callProcesses = try AudioProcessProbe.inputRunningCallProcesses()

            print("")
            print("[\(timestamp)] sample \(iteration + 1)/\(iterations)")
            for snapshot in snapshots {
                print(format(snapshot: snapshot))
            }

            if callProcesses.isEmpty {
                print("Input-running known call processes: none")
            } else {
                print("Input-running known call processes:")
                for process in callProcesses {
                    print("- \(format(process: process, label: process.callMatch?.name))")
                }
            }

            if inputProcesses.isEmpty {
                print("All input-running Core Audio processes: none")
            } else {
                print("All input-running Core Audio processes:")
                for process in inputProcesses {
                    print("- \(format(process: process, label: nil))")
                }
            }

            if iteration < iterations - 1 {
                let nanoseconds = UInt64(configuration.intervalSeconds * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
            }
        }

        print("")
        print("Diagnostic complete. If this was run during a real call, compare the 'duck' raw bytes across no-call vs in-call samples.")
    }

    private func format(snapshot: DuckPropertySnapshot) -> String {
        guard snapshot.hasProperty else {
            return "'duck' property [\(snapshot.scopeName)]: not present on device \(snapshot.deviceID)"
        }

        let floatDescription = snapshot.float32Values.isEmpty
            ? "n/a"
            : snapshot.float32Values.map { String(format: "%.6f", $0) }.joined(separator: ", ")

        return "'duck' property [\(snapshot.scopeName)]: bytes=\(snapshot.rawBytes.count) allZero=\(snapshot.isAllZero) hex=[\(snapshot.hex)] float32=[\(floatDescription)]"
    }

    private func format(process: AudioProcessInfo, label: String?) -> String {
        let prefix = label.map { "\($0): " } ?? ""
        let pid = process.pid.map(String.init) ?? "unknown"
        let name = process.processName ?? "unknown"
        let bundle = process.bundleID ?? "unknown"
        return "\(prefix)object=\(process.objectID) pid=\(pid) name=\(name) bundle=\(bundle)"
    }
}

public enum Phase0Error: Error, CustomStringConvertible, Sendable {
    case unsupportedOS

    public var description: String {
        switch self {
        case .unsupportedOS:
            "Duck Audio requires macOS 14.2+ because Core Audio process taps were introduced there."
        }
    }
}
