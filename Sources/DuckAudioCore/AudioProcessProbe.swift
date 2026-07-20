import AppKit
import CoreAudio
import Foundation

public struct AudioProcessInfo: Equatable, Sendable {
    public let objectID: AudioObjectID
    public let pid: pid_t?
    public let bundleID: String?
    public let processName: String?
    public let isRunning: Bool
    public let isRunningInput: Bool
    public let isRunningOutput: Bool

    public init(
        objectID: AudioObjectID,
        pid: pid_t?,
        bundleID: String?,
        processName: String?,
        isRunning: Bool,
        isRunningInput: Bool,
        isRunningOutput: Bool
    ) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.processName = processName
        self.isRunning = isRunning
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }

    public var callMatch: KnownCallApp? {
        KnownCallApp.match(bundleID: bundleID, processName: processName)
    }
}

public struct KnownCallApp: Equatable, Sendable {
    public let name: String
    public let bundleIDNeedle: String
    public let family: String

    public init(name: String, bundleIDNeedle: String, family: String) {
        self.name = name
        self.bundleIDNeedle = bundleIDNeedle
        self.family = family
    }

    public static let knownApps: [KnownCallApp] = [
        KnownCallApp(name: "FaceTime", bundleIDNeedle: "com.apple.FaceTime", family: "facetime"),
        KnownCallApp(name: "FaceTime audio service", bundleIDNeedle: "avconferenced", family: "facetime"),
        KnownCallApp(name: "Zoom", bundleIDNeedle: "zoom", family: "zoom"),
        KnownCallApp(name: "Microsoft Teams", bundleIDNeedle: "teams", family: "teams"),
        KnownCallApp(name: "Webex", bundleIDNeedle: "webex", family: "webex"),
        KnownCallApp(name: "Discord", bundleIDNeedle: "discord", family: "discord"),
        KnownCallApp(name: "Slack", bundleIDNeedle: "slack", family: "slack"),
        KnownCallApp(name: "Google Chrome / Meet", bundleIDNeedle: "com.google.Chrome", family: "chrome"),
        KnownCallApp(name: "Safari / Meet", bundleIDNeedle: "com.apple.Safari", family: "safari")
    ]

    public static func match(bundleID: String?, processName: String?) -> KnownCallApp? {
        let lowercasedBundleID = bundleID?.lowercased() ?? ""
        let lowercasedProcessName = processName?.lowercased() ?? ""
        return knownApps.first { app in
            let needle = app.bundleIDNeedle.lowercased()
            return lowercasedBundleID.contains(needle) || lowercasedProcessName.contains(needle)
        }
    }
}

public enum AudioProcessProbe {
    public static func allProcesses() throws -> [AudioProcessInfo] {
        let objectIDs = try CoreAudioProperty.readAudioObjectIDs(
            objectID: AudioObjectID(kAudioObjectSystemObject),
            address: CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        )

        return objectIDs.map { objectID in
            let pid = try? CoreAudioProperty.readInt32(
                objectID: objectID,
                address: CoreAudioProperty.address(kAudioProcessPropertyPID)
            )
            let runningApplication = pid.flatMap { NSRunningApplication(processIdentifier: $0) }

            return AudioProcessInfo(
                objectID: objectID,
                pid: pid,
                bundleID: try? CoreAudioProperty.readCFString(
                    objectID: objectID,
                    address: CoreAudioProperty.address(kAudioProcessPropertyBundleID)
                ),
                processName: runningApplication?.localizedName,
                isRunning: (try? CoreAudioProperty.readUInt32(
                    objectID: objectID,
                    address: CoreAudioProperty.address(kAudioProcessPropertyIsRunning)
                )) == 1,
                isRunningInput: (try? CoreAudioProperty.readUInt32(
                    objectID: objectID,
                    address: CoreAudioProperty.address(kAudioProcessPropertyIsRunningInput)
                )) == 1,
                isRunningOutput: (try? CoreAudioProperty.readUInt32(
                    objectID: objectID,
                    address: CoreAudioProperty.address(kAudioProcessPropertyIsRunningOutput)
                )) == 1
            )
        }
        .sorted { lhs, rhs in
            (lhs.bundleID ?? lhs.processName ?? "") < (rhs.bundleID ?? rhs.processName ?? "")
        }
    }

    public static func inputRunningProcesses() throws -> [AudioProcessInfo] {
        try allProcesses()
            .filter { $0.isRunningInput }
    }

    public static func inputRunningCallProcesses() throws -> [AudioProcessInfo] {
        try inputRunningProcesses()
            .filter { $0.isRunningInput && $0.callMatch != nil }
    }

    public static func currentProcessObjectID() throws -> AudioObjectID {
        try CoreAudioProperty.translatePIDToProcessObject(getpid())
    }

    /// Apps currently producing audio OUTPUT (i.e. things you'd want a volume
    /// slider for), excluding our own process. Read-only; used by the menu list.
    public static func outputRunningProcesses() throws -> [AudioProcessInfo] {
        let me = (try? currentProcessObjectID()) ?? kAudioObjectUnknown
        return try allProcesses().filter { proc in
            proc.isRunningOutput
                && proc.objectID != me
                && (proc.processName != nil || proc.bundleID != nil)
        }
    }

    /// Every app that has an audio session (a bundle id), whether or not it is
    /// playing *right now* — so an open media app still gets a slider while paused.
    public static func audioSessionProcesses() throws -> [AudioProcessInfo] {
        let me = (try? currentProcessObjectID()) ?? kAudioObjectUnknown
        return try allProcesses().filter { $0.objectID != me && $0.bundleID != nil }
    }
}
