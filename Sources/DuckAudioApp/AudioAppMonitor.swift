import SwiftUI
import AppKit
import DuckAudioCore

/// One row in the menu: an app currently producing audio.
struct AudioAppItem: Identifiable {
    let id: String          // stable key (responsible app pid / bundle id)
    let name: String
    let bundleID: String?
    let icon: NSImage?
    let isCallApp: Bool
}

/// Polls (~1 Hz) for apps currently producing audio output and publishes them
/// for the menu. Phase 1: read-only — it only lists; no volume control yet.
///
/// macOS audio is produced by *helper* processes (e.g. "Safari Graphics and
/// Media", "Google Chrome Helper", "avconferenced"). We resolve each helper up
/// to the **responsible parent app** so the list shows "Safari", "Chrome",
/// "FaceTime" with proper names and icons.
@MainActor
final class AudioAppMonitor: ObservableObject {
    @Published private(set) var apps: [AudioAppItem] = []

    private var timer: Timer?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let procs = (try? AudioProcessProbe.outputRunningProcesses()) ?? []

        var items: [AudioAppItem] = []
        var seen = Set<String>()

        for proc in procs {
            let isCall = proc.callMatch != nil

            // Resolve the helper process to its responsible parent app.
            var app: NSRunningApplication?
            if let pid = proc.pid {
                let responsible = Self.responsiblePID(for: pid)
                app = NSRunningApplication(processIdentifier: responsible)
                    ?? NSRunningApplication(processIdentifier: pid)
            }

            // Decide the display name + icon.
            let name: String
            let icon: NSImage?
            let bundleID: String?
            if let app, let localized = app.localizedName, app.activationPolicy == .regular {
                // A real, user-facing app (Safari, Chrome, Music, FaceTime…).
                name = localized
                icon = app.icon
                bundleID = app.bundleIdentifier
            } else if isCall {
                // A background call service (e.g. avconferenced) — label it nicely.
                name = friendlyCallName(proc)
                icon = callIcon()
                bundleID = proc.bundleID
            } else {
                // A background daemon that isn't a user app — skip it.
                continue
            }

            let key = bundleID ?? name
            if seen.contains(key) { continue }   // one row per app
            seen.insert(key)

            items.append(AudioAppItem(id: key, name: name, bundleID: bundleID, icon: icon, isCallApp: isCall))
        }

        apps = items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Helpers

    /// Map a call helper to a friendly name.
    private func friendlyCallName(_ proc: AudioProcessInfo) -> String {
        let needle = (proc.bundleID ?? proc.processName ?? "").lowercased()
        if needle.contains("avconference") || needle.contains("facetime") { return "FaceTime" }
        return proc.callMatch?.name ?? proc.processName ?? "Call"
    }

    /// Icon for a call service that has no GUI app: prefer FaceTime's icon.
    private func callIcon() -> NSImage? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "phone.fill", accessibilityDescription: "Call")
    }

    /// Resolved once and reused (this is called for every audio process on
    /// every poll, so re-looking-up the symbol each time was wasteful).
    private static let responsibilityFn: (@convention(c) (pid_t) -> pid_t)? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(sym, to: (@convention(c) (pid_t) -> pid_t).self)
    }()

    /// The process responsible for `pid` (a helper's parent app), via the
    /// private but widely-used responsibility API. Falls back to `pid`.
    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let fn = responsibilityFn else { return pid }
        let responsible = fn(pid)
        return responsible > 0 ? responsible : pid
    }
}
