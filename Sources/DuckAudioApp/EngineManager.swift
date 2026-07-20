import SwiftUI
import DuckAudioCore
import AVFoundation
import AppKit
import Foundation
import ServiceManagement

/// One row in the mixer: a parent app with a volume.
struct MixerApp: Identifiable {
    let id: String                 // app key (bundle id)
    let name: String
    let icon: NSImage?
    let isFavorite: Bool
    let isActive: Bool             // currently producing audio
    var volume: Double             // 0…1.5
    var muted: Bool
    let processObjectIDs: [AudioObjectID]   // its currently-playing processes
}

/// An entry in the "Add Favorite" menu.
struct RunningAppItem: Identifiable, Equatable {
    let id: String                 // bundle id
    let name: String
    let icon: NSImage?

    // Compare by identity only — icons rarely change and NSImage has no value
    // equality, so this lets us skip needless @Published churn each poll.
    static func == (lhs: RunningAppItem, rhs: RunningAppItem) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

@MainActor
final class EngineManager: ObservableObject, CallWatcherDelegate {
    @Published var isRunning = false
    @Published var isInCall = false
    @Published var apps: [MixerApp] = []
    @Published var runningApps: [RunningAppItem] = []
    @Published var error: Error?

    /// Whether the app is registered to launch at login (Settings toggle).
    @Published var launchAtLogin: Bool = false

    /// Update state (auto-checked against GitHub Releases).
    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var isCheckingUpdate = false
    let currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    let releasesURL = "https://github.com/MrRockySL/Unduck-Pro/releases/latest"
    let issuesURL = "https://github.com/MrRockySL/Unduck-Pro/issues"
    private var didCheckUpdates = false

    // Master system output (the normal macOS volume).
    @Published var systemVolume: Double = 1.0
    @Published var systemMuted: Bool = false
    @Published var outputDeviceName: String = "Output"
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var outputDeviceID: AudioDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var lastSystemVolumeSet = Date.distantPast

    private let engine = PerAppTapEngine(limiterCeiling: 0.9)
    private let callWatcher = CallWatcher(pollInterval: 1.0)
    private var timer: Timer?

    private var volumes: [String: Double] = [:]
    private var mutes: [String: Bool] = [:]
    private var favorites: Set<String> = []
    private let favKey = "UnduckProFavorites"
    private let volKey = "UnduckProVolumes"

    private var lastTapSet: Set<AudioObjectID> = []
    private var lastCallSet: Set<AudioObjectID> = []
    private var isStarting = false
    private var menuVisible = false
    private var runningAppsTickCounter = 0
    private var rebuildRetryTask: Task<Void, Never>?

    init() {
        favorites = Set(UserDefaults.standard.stringArray(forKey: favKey) ?? [])
        if let saved = UserDefaults.standard.dictionary(forKey: volKey) as? [String: Double] {
            volumes = saved
        }
    }

    // MARK: - Engine lifecycle

    func startEngine() {
        guard !isRunning, !isStarting else { return }
        error = nil
        isStarting = true
        AVAudioApplication.requestRecordPermission { granted in
            guard granted else {
                Task { @MainActor in
                    self.isStarting = false
                    self.error = NSError(domain: "UnduckPro", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Microphone access is required."])
                }
                return
            }
            // The heavy CoreAudio setup (creating taps, the aggregate device and
            // the IO proc) runs OFF the main thread — doing it on main blocked
            // the menu from rendering, so the first open hung for seconds.
            DispatchQueue.global(qos: .userInitiated).async {
                self.callWatcher.delegate = self
                self.callWatcher.start()
                self.engine.excludedCallIDs = self.callWatcher.currentState.excludedObjectIDs
                do {
                    try self.engine.start()
                } catch {
                    Task { @MainActor in
                        self.isStarting = false
                        self.error = error
                        self.callWatcher.stop()
                    }
                    return
                }
                Task { @MainActor in
                    self.isStarting = false
                    self.lastCallSet = self.engine.excludedCallIDs
                    self.lastTapSet = self.callWatcher.currentOutputObjectIDs
                    self.isRunning = true
                    // Only spin up the polling timer + first refresh if the panel
                    // is actually open; otherwise the engine just runs quietly.
                    if self.menuVisible { self.tick(); self.startUITimer() }
                }
            }
        }
    }

    func stopEngine() {
        guard isRunning else { return }
        stopUITimer()
        rebuildRetryTask?.cancel(); rebuildRetryTask = nil
        callWatcher.stop()
        try? engine.stop()
        isRunning = false
        apps = []
    }

    // MARK: - Panel visibility

    /// Called when the menu panel opens. Starts the engine (idempotent) and
    /// resumes live UI polling.
    func menuDidOpen() {
        menuVisible = true
        runningAppsTickCounter = 0   // refresh the Add-Favorite list right away
        refreshLaunchAtLogin()       // keep the Settings toggle in sync
        startEngine()                // the engine runs whenever the app is open
        if isRunning { tick(); startUITimer() }
    }

    /// Called when the panel closes. The engine, un-duck loop and call watcher
    /// keep running; only the (relatively expensive) UI refresh poll stops, so
    /// the app idles cheaply while still keeping media loud during calls.
    func menuDidClose() {
        menuVisible = false
        stopUITimer()
    }

    private func startUITimer() {
        guard timer == nil, isRunning, menuVisible else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }   // fires on the main run loop
        }
    }

    private func stopUITimer() {
        timer?.invalidate(); timer = nil
    }

    // MARK: - Background audio maintenance

    /// Fired whenever the lightweight watcher sees a call transition OR a change
    /// in output-producing apps. This remains active with the panel closed, so
    /// tap maintenance no longer depends on opening the menu-bar window.
    nonisolated func callWatcher(_ watcher: CallWatcher, didChangeState newState: CallState,
                                 exclusionSetChanged: Bool) {
        let outputIDs = watcher.currentOutputObjectIDs
        Task { @MainActor in self.reconcileAudioState(newState, outputIDs: outputIDs) }
    }

    private func reconcileAudioState(_ state: CallState, outputIDs: Set<AudioObjectID>) {
        guard isRunning else { return }
        isInCall = state.isInCall
        let callSet = state.excludedObjectIDs
        let outputsChanged = outputIDs != lastTapSet
        let callsChanged = callSet != lastCallSet
        guard outputsChanged || callsChanged else { return }

        engine.excludedCallIDs = callSet
        do {
            try engine.rebuild()
            lastTapSet = outputIDs
            lastCallSet = callSet
            rebuildRetryTask?.cancel(); rebuildRetryTask = nil
            reapplyGains()
            print("[engine] taps refreshed: outputs=\(outputIDs.count) calls=\(callSet.count)")
        } catch {
            fputs("[engine] tap refresh failed: \(error)\n", stderr)
            scheduleRebuildRetry()
        }
    }

    /// A transient HAL failure must not leave the app waiting for the user to
    /// open the menu. Retry against the latest watcher snapshot after one second.
    private func scheduleRebuildRetry() {
        guard rebuildRetryTask == nil else { return }
        rebuildRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.rebuildRetryTask = nil
            self.reconcileAudioState(
                self.callWatcher.currentState,
                outputIDs: self.callWatcher.currentOutputObjectIDs
            )
        }
    }

    // MARK: - Controls

    func setVolume(_ v: Double, for app: MixerApp) {
        volumes[app.id] = v
        UserDefaults.standard.set(volumes, forKey: volKey)   // remembered, applied when it next plays
        for pid in app.processObjectIDs { engine.setGain(Float(v), forProcess: pid) }
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].volume = v }
    }

    func toggleMute(_ app: MixerApp) {
        let newMuted = !(mutes[app.id] ?? false)
        mutes[app.id] = newMuted
        for pid in app.processObjectIDs { engine.setMuted(newMuted, forProcess: pid) }
        if let i = apps.firstIndex(where: { $0.id == app.id }) { apps[i].muted = newMuted }
    }

    func setSystemVolume(_ v: Double) {
        lastSystemVolumeSet = Date()
        SystemVolume.setVolume(Float(v))
        systemVolume = v
    }

    /// Switch the macOS default output device (built-in ↔ AirPods ↔ external…).
    func setOutputDevice(_ id: AudioDeviceID) {
        SystemVolume.setDefaultOutputDevice(id)
        outputDeviceID = id
        outputDeviceName = SystemVolume.deviceName()
        systemMuted = SystemVolume.isMuted()
        if let v = SystemVolume.volume() { systemVolume = Double(v) }
        lastSystemVolumeSet = Date()
    }

    func toggleSystemMute() {
        let m = !systemMuted
        SystemVolume.setMuted(m)
        systemMuted = m
    }

    // MARK: - Launch at login

    /// Read the current login-item registration into `launchAtLogin`.
    func refreshLaunchAtLogin() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }

    /// Register/unregister the app as a login item.
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = on
        } catch {
            // Reflect the real state if the system rejected the change.
            refreshLaunchAtLogin()
        }
    }

    // MARK: - Updates

    /// Ask GitHub whether a newer release exists. Runs once per launch unless forced.
    func checkForUpdates(force: Bool = false) {
        if (didCheckUpdates && !force) || isCheckingUpdate { return }
        didCheckUpdates = true
        isCheckingUpdate = true
        Task { await performUpdateCheck() }
    }

    private func performUpdateCheck() async {
        let started = Date()
        defer {
            // Keep "Checking…" visible briefly so the button gives feedback even
            // when the network answers instantly.
            let elapsed = Date().timeIntervalSince(started)
            let remaining = max(0, 0.7 - elapsed)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                self.isCheckingUpdate = false
            }
        }
        guard let url = URL(string: "https://api.github.com/repos/MrRockySL/Unduck-Pro/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else { return }
            let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            latestVersion = latest
            updateAvailable = Self.isVersion(latest, newerThan: currentVersion)
        } catch {
            // Offline or rate-limited — leave the state unchanged.
        }
    }

    /// Numeric "1.2.0" > "1.1" comparison.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Reset

    /// Clear all saved per-app volumes, mutes and favorites.
    func resetVolumesAndFavorites() {
        volumes.removeAll(); mutes.removeAll(); favorites.removeAll()
        UserDefaults.standard.removeObject(forKey: volKey)
        UserDefaults.standard.removeObject(forKey: favKey)
        reapplyGains()        // currently-playing apps fall back to 100%
        rebuildAppList()
    }

    func toggleFavorite(_ app: MixerApp) {
        if favorites.contains(app.id) { favorites.remove(app.id) } else { favorites.insert(app.id) }
        saveFavorites(); rebuildAppList()
    }

    func addFavorite(_ item: RunningAppItem) {
        favorites.insert(item.id); saveFavorites(); rebuildAppList()
    }

    private func saveFavorites() { UserDefaults.standard.set(Array(favorites), forKey: favKey) }

    // MARK: - Polling / rebuild

    private func tick() {
        let callState = callWatcher.currentState
        isInCall = callState.isInCall

        // Master system output — don't override while the user is dragging it.
        outputDeviceName = SystemVolume.deviceName()
        outputDeviceID = SystemVolume.defaultOutputDevice()
        let devs = SystemVolume.outputDevices()
        if devs != outputDevices { outputDevices = devs }   // avoid needless view churn
        systemMuted = SystemVolume.isMuted()
        if Date().timeIntervalSince(lastSystemVolumeSet) > 1.0, let v = SystemVolume.volume() {
            systemVolume = Double(v)
        }

        // The running-app list (for "Add Favorite") changes rarely and is the
        // most expensive part of the poll, so refresh it only occasionally.
        if runningAppsTickCounter % 3 == 0 { refreshRunningApps() }
        runningAppsTickCounter += 1
        rebuildAppList()
    }

    private func reapplyGains() {
        for (key, info) in groupActiveApps() {
            let v = volumes[key] ?? 1.0
            let m = mutes[key] ?? false
            for pid in info.processIDs {
                engine.setGain(Float(v), forProcess: pid)
                engine.setMuted(m, forProcess: pid)
            }
        }
    }

    private func rebuildAppList() {
        let active = groupActiveApps()
        var rows: [MixerApp] = []
        var included = Set<String>()

        // Currently-playing apps (rise to top; can be starred).
        for (key, info) in active {
            rows.append(MixerApp(
                id: key, name: info.name, icon: info.icon,
                isFavorite: favorites.contains(key), isActive: true,
                volume: volumes[key] ?? 1.0, muted: mutes[key] ?? false,
                processObjectIDs: info.processIDs))
            included.insert(key)
        }

        // Favorites that aren't playing but are still open — always shown.
        for key in favorites where !included.contains(key) {
            guard let item = runningApp(bundleID: key) else { continue }
            rows.append(MixerApp(
                id: key, name: item.name, icon: item.icon,
                isFavorite: true, isActive: false,
                volume: volumes[key] ?? 1.0, muted: mutes[key] ?? false,
                processObjectIDs: []))
            included.insert(key)
        }

        apps = rows.sorted {
            if $0.isActive != $1.isActive { return $0.isActive }      // playing on top
            if $0.isFavorite != $1.isFavorite { return $0.isFavorite } // then favorites
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func refreshRunningApps() {
        let fresh = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular
                && $0.bundleIdentifier != nil
                && $0.bundleIdentifier != "dev.mrrockysl.duckaudio" }
            .map { RunningAppItem(id: $0.bundleIdentifier!, name: $0.localizedName ?? $0.bundleIdentifier!, icon: $0.icon) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if fresh != runningApps { runningApps = fresh }   // skip needless view churn
    }

    private func runningApp(bundleID: String) -> RunningAppItem? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else { return nil }
        return RunningAppItem(id: bundleID, name: app.localizedName ?? bundleID, icon: app.icon)
    }

    private struct GroupInfo { var name: String; var icon: NSImage?; var processIDs: [AudioObjectID] }

    /// Currently-playing apps grouped by their parent GUI app. Call apps are
    /// included so the call itself (FaceTime / Zoom…) gets a working slider.
    private func groupActiveApps() -> [String: GroupInfo] {
        var groups: [String: GroupInfo] = [:]
        for tapped in engine.tappedApps {
            let respPID = AudioAppMonitor.responsiblePID(for: tapped.pid)
            let app = NSRunningApplication(processIdentifier: respPID)
                ?? NSRunningApplication(processIdentifier: tapped.pid)
            if let app, app.activationPolicy == .regular, let name = app.localizedName,
               let key = app.bundleIdentifier {
                if groups[key] == nil { groups[key] = GroupInfo(name: name, icon: app.icon, processIDs: []) }
                groups[key]?.processIDs.append(tapped.processObjectID)
            } else if tapped.isCall {
                // Call service daemons (e.g. avconferenced, which plays FaceTime's
                // call audio) have no regular GUI app, so the lookup above fails.
                // Group them under their call app so the slider actually controls
                // the call audio.
                let bid = tapped.bundleID ?? ""
                let isFaceTime = bid.localizedCaseInsensitiveContains("avconferenced")
                    || bid.localizedCaseInsensitiveContains("facetime")
                let key = isFaceTime ? "com.apple.FaceTime" : (tapped.bundleID ?? "call.\(tapped.pid)")
                let gui = NSRunningApplication.runningApplications(withBundleIdentifier: key).first
                let fallbackName = KnownCallApp.match(bundleID: bid, processName: nil)?.name
                let name = gui?.localizedName ?? (isFaceTime ? "FaceTime" : (fallbackName ?? "Call"))
                let icon = gui?.icon
                    ?? (isFaceTime ? NSWorkspace.shared.icon(forFile: "/System/Applications/FaceTime.app") : nil)
                if groups[key] == nil { groups[key] = GroupInfo(name: name, icon: icon, processIDs: []) }
                groups[key]?.processIDs.append(tapped.processObjectID)
            }
        }
        return groups
    }
}
