import DuckAudioCore
import Darwin
import Foundation

@main
struct DuckAudioSelfTest {
    static func main() {
        var failures: [String] = []

        expect(
            HardLimiter(ceiling: 0.75).process([-2, -0.5, 0, 0.5, 2]) == [-0.75, -0.5, 0, 0.5, 0.75],
            "limiter clamps to configured ceiling",
            failures: &failures
        )

        expect(
            HardLimiter().process([.nan, .infinity, -.infinity, 0.25]) == [0, 0, 0, 0.25],
            "limiter converts non-finite samples to silence",
            failures: &failures
        )

        var cappedStage = SafeGainStage(
            config: SafeGainConfig(
                maxGain: 4,
                maxGainStepPerBuffer: 10,
                limiter: HardLimiter(ceiling: 0.8)
            )
        )
        let capped = cappedStage.process(samples: [0.5, -0.5], requestedGain: 100)
        expect(capped.appliedGain == 4, "safe gain caps requested gain", failures: &failures)
        expect(capped.samples == [0.8, -0.8], "safe gain output is hard-limited", failures: &failures)
        expect(capped.outputLevels.peak <= 0.8, "safe gain measured peak respects ceiling", failures: &failures)

        var analysisStage = SafeGainStage(
            config: SafeGainConfig(
                maxGain: 4,
                maxGainStepPerBuffer: 10,
                limiter: HardLimiter(ceiling: 0.8)
            )
        )
        let analysisSamples: [Float32] = [0.5, -0.25, 0]
        let analysis = analysisSamples.withUnsafeBufferPointer { buffer in
            analysisStage.analyze(samples: buffer, requestedGain: 100)
        }
        expect(analysis.appliedGain == 4, "safe gain analysis caps requested gain", failures: &failures)
        expect(analysis.inputLevels.peak == 0.5, "safe gain analysis input peak", failures: &failures)
        expect(analysis.outputLevels.peak == 0.8, "safe gain analysis output peak is limited", failures: &failures)
        expect(analysis.sampleCount == 3, "safe gain analysis sample count", failures: &failures)
        expect(analysis.limitedSampleCount == 2, "safe gain analysis limited sample count", failures: &failures)

        var outputStage = SafeGainStage(
            config: SafeGainConfig(
                maxGain: 4,
                maxGainStepPerBuffer: 10,
                limiter: HardLimiter(ceiling: 0.8)
            )
        )
        let outputInput: [Float32] = [0.5, -0.25, 0]
        var outputSamples = [Float32](repeating: 99, count: 5)
        let outputResult = outputInput.withUnsafeBufferPointer { inputBuffer in
            outputSamples.withUnsafeMutableBufferPointer { outputBuffer in
                outputStage.process(input: inputBuffer, output: outputBuffer, requestedGain: 100)
            }
        }
        expect(outputResult.appliedGain == 4, "safe gain output path caps requested gain", failures: &failures)
        expect(Array(outputSamples.prefix(3)) == [0.8, -0.8, 0], "safe gain output path writes limited samples", failures: &failures)
        expect(Array(outputSamples.suffix(2)) == [0, 0], "safe gain output path clears extra output samples", failures: &failures)
        expect(outputResult.limitedSampleCount == 2, "safe gain output path limited sample count", failures: &failures)

        var slewStage = SafeGainStage(
            config: SafeGainConfig(
                maxGain: 10,
                maxGainStepPerBuffer: 0.5,
                limiter: HardLimiter()
            )
        )
        let first = slewStage.process(samples: [0.1], requestedGain: 8)
        let second = slewStage.process(samples: [0.1], requestedGain: 8)
        expect(first.appliedGain == 1.5, "safe gain first slew step", failures: &failures)
        expect(second.appliedGain == 2.0, "safe gain second slew step", failures: &failures)

        var fastFallStage = SafeGainStage(
            config: SafeGainConfig(
                maxGain: 10,
                maxGainStepPerBuffer: 0.5,
                maxGainFallPerBuffer: 10,
                limiter: HardLimiter()
            ),
            initialGain: 10
        )
        let fastFall = fastFallStage.process(samples: [0.1], requestedGain: 2)
        expect(fastFall.appliedGain == 2, "safe gain falls quickly for headroom", failures: &failures)

        let levels = LevelMeter.measure([1, -1, 0, 0])
        expect(levels.peak == 1, "level meter peak", failures: &failures)
        expect(abs(levels.rms - 0.70710677) < 0.0001, "level meter RMS", failures: &failures)

        // CallState tests
        let noCall = CallState.noCall
        expect(!noCall.isInCall, "noCall.isInCall is false", failures: &failures)
        expect(noCall.excludedObjectIDs.isEmpty, "noCall has no excluded IDs", failures: &failures)

        let proc1 = CallProcessInfo(objectID: 42, pid: 123, bundleID: "com.apple.FaceTime", matchedName: "FaceTime")
        let proc2 = CallProcessInfo(objectID: 99, pid: 456, bundleID: "avconferenced", matchedName: "FaceTime audio service")
        let inCall = CallState.inCall(processes: [proc1, proc2])
        expect(inCall.isInCall, "inCall.isInCall is true", failures: &failures)
        expect(inCall.excludedObjectIDs == Set([42, 99]), "inCall excludes correct IDs", failures: &failures)

        // CallState equality
        let inCall2 = CallState.inCall(processes: [proc1, proc2])
        expect(inCall == inCall2, "identical inCall states are equal", failures: &failures)
        expect(noCall != inCall, "noCall != inCall", failures: &failures)

        let singleCall = CallState.inCall(processes: [proc1])
        expect(singleCall.excludedObjectIDs == Set([42]), "single process exclusion", failures: &failures)
        expect(singleCall != inCall, "different process counts not equal", failures: &failures)

        // The always-on watcher must derive call and output changes from one
        // process scan, including helpers while excluding our own process.
        let activityProcesses = [
            AudioProcessInfo(objectID: 10, pid: 10, bundleID: "dev.mrrockysl.duckaudio",
                             processName: "Unduck Pro", isRunning: true,
                             isRunningInput: false, isRunningOutput: true),
            AudioProcessInfo(objectID: 42, pid: 123, bundleID: "com.apple.FaceTime",
                             processName: "FaceTime", isRunning: true,
                             isRunningInput: true, isRunningOutput: true),
            AudioProcessInfo(objectID: 77, pid: 777, bundleID: "com.google.Chrome.helper",
                             processName: "Google Chrome Helper", isRunning: true,
                             isRunningInput: false, isRunningOutput: true),
            AudioProcessInfo(objectID: 88, pid: nil, bundleID: nil,
                             processName: nil, isRunning: true,
                             isRunningInput: false, isRunningOutput: true)
        ]
        let activity = CallWatcher.makeSnapshot(processes: activityProcesses, selfObjectID: 10)
        expect(activity.callState.isInCall, "activity snapshot detects live call input", failures: &failures)
        expect(activity.callState.excludedObjectIDs == Set([42]),
               "activity snapshot identifies call process", failures: &failures)
        expect(activity.outputObjectIDs == Set([42, 77]),
               "activity snapshot tracks output apps and excludes self/background daemons", failures: &failures)

        // TapEngineConfiguration defaults
        let defaultConfig = TapEngineConfiguration()
        expect(defaultConfig.callGain == 1, "default callGain is 1", failures: &failures)
        expect(defaultConfig.limiterCeiling == 0.90, "default limiter ceiling is 0.90", failures: &failures)
        expect(defaultConfig.autoHeadroom == true, "default autoHeadroom is true", failures: &failures)

        if failures.isEmpty {
            print("Duck Audio self-test passed")
        } else {
            for failure in failures {
                fputs("FAIL: \(failure)\n", stderr)
            }
            exit(1)
        }
    }

    private static func expect(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition {
            failures.append(message)
        }
    }
}
