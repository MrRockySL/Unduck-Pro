import SwiftUI
import AppKit
import DuckAudioCore

/// Unduck Pro is menu-bar only: every piece of its UI lives in the custom
/// panel owned by `StatusBarController`, so it runs on a plain AppKit entry
/// point instead of the SwiftUI `App` lifecycle.
///
/// It used to declare `Settings { EmptyView() }` purely to satisfy SwiftUI's
/// rule that an `App` must have at least one scene. macOS opened that scene on
/// launch, so an empty "Unduck Pro Settings" window appeared every time and had
/// to be closed by hand. With no scene graph there is no window for the system
/// to open or restore.
@main
@MainActor
enum DuckAudioMain {
    /// `NSApplication` holds its delegate weakly, so it is retained here.
    private static var appDelegate: DuckAudioAppDelegate?

    static func main() {
        redirectOutputToLogFile()

        let application = NSApplication.shared
        let delegate = DuckAudioAppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.run()
    }

    private static func redirectOutputToLogFile() {
        let logPath = "/tmp/duckaudio.log"
        freopen(logPath, "w", stdout)
        freopen(logPath, "w", stderr)
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        print("UnduckPro started")
    }
}

// MARK: - Theme (Minimal · Calm)

enum Theme {
    static let bg      = Color(red: 30/255, green: 30/255, blue: 30/255)
    static let surface = Color(red: 42/255, green: 42/255, blue: 42/255)
    static let surfaceHover = Color(red: 51/255, green: 51/255, blue: 51/255)
    static let border  = Color(red: 58/255, green: 58/255, blue: 58/255)

    static let ink  = Color(red: 232/255, green: 232/255, blue: 232/255)
    static let ink2 = Color(red: 153/255, green: 153/255, blue: 153/255)
    static let ink3 = Color(red: 102/255, green: 102/255, blue: 102/255)

    static let accent     = Color(red: 108/255, green: 160/255, blue: 220/255)
    static let accentSoft = Color(red: 108/255, green: 160/255, blue: 220/255).opacity(0.15)

    static let red = Color(red: 217/255, green: 115/255, blue: 115/255)
}

// MARK: - Duck glyph (drawn from the same primitives as the SVG logo)

struct DuckGlyph: View {
    var bodyColor: Color
    var billColor: Color
    var eyeColor: Color?

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 24.0
            // body
            let body = CGRect(x: (10 - 7.7) * s, y: (14.6 - 5.3) * s, width: 7.7 * 2 * s, height: 5.3 * 2 * s)
            ctx.fill(Path(ellipseIn: body), with: .color(bodyColor))
            // head
            let head = CGRect(x: (14.3 - 4.7) * s, y: (9 - 4.7) * s, width: 4.7 * 2 * s, height: 4.7 * 2 * s)
            ctx.fill(Path(ellipseIn: head), with: .color(bodyColor))
            // bill (rotated -7° about 16.3,9.4)
            var bill = Path(roundedRect: CGRect(x: 16.3 * s, y: 7.7 * s, width: 6.6 * s, height: 3.1 * s),
                            cornerRadius: 1.55 * s)
            let ax = 16.3 * s, ay = 9.4 * s
            let tf = CGAffineTransform(translationX: ax, y: ay)
                .rotated(by: -7 * .pi / 180)
                .translatedBy(x: -ax, y: -ay)
            bill = bill.applying(tf)
            ctx.fill(bill, with: .color(billColor))
            // eye
            if let eyeColor {
                let eye = CGRect(x: (14.7 - 1.05) * s, y: (8.5 - 1.05) * s, width: 1.05 * 2 * s, height: 1.05 * 2 * s)
                ctx.fill(Path(ellipseIn: eye), with: .color(eyeColor))
            }
        }
        .aspectRatio(24.0 / 24.0, contentMode: .fit)
    }
}

// MARK: - Menu-bar glyph (template NSImage — same duck primitives)

enum MenuBarGlyph {
    static let image: NSImage = make()

    private static func make() -> NSImage {
        let unit: CGFloat = 24
        let target: CGFloat = 18
        let img = NSImage(size: NSSize(width: target, height: target), flipped: true) { _ in
            let s = target / unit
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x * s, y: y * s, width: w * s, height: h * s)
            }
            NSColor.black.setFill()
            // body
            NSBezierPath(ovalIn: r(10 - 7.7, 14.6 - 5.3, 15.4, 10.6)).fill()
            // head
            NSBezierPath(ovalIn: r(14.3 - 4.7, 9 - 4.7, 9.4, 9.4)).fill()
            // bill (7° tilt is imperceptible at this size → drawn flat)
            NSBezierPath(roundedRect: r(16.3, 7.7, 6.6, 3.1), xRadius: 1.55 * s, yRadius: 1.55 * s).fill()
            return true
        }
        img.isTemplate = true   // adapts to light/dark menu bars
        return img
    }
}

// MARK: - Animated equalizer bars

struct EQBars: View {
    var active: Bool
    var color: Color
    var bases: [CGFloat]          // resting heights per bar
    var phases: [Double]          // animation phase per bar
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5
    var period: Double = 1.0

    init(active: Bool, color: Color,
         bases: [CGFloat] = [7, 14, 9, 12],
         phases: [Double] = [0, 0.35, 0.6, 0.15],
         barWidth: CGFloat = 3, spacing: CGFloat = 2.5) {
        self.active = active; self.color = color
        self.bases = bases; self.phases = phases
        self.barWidth = barWidth; self.spacing = spacing
    }

    private var maxBase: CGFloat { bases.max() ?? 14 }

    var body: some View {
        Group {
            if active {
                TimelineView(.animation) { tl in
                    let t = tl.date.timeIntervalSinceReferenceDate
                    bars(time: t)
                }
            } else {
                bars(time: nil)
            }
        }
        .frame(height: maxBase, alignment: .bottom)
    }

    @ViewBuilder private func bars(time: Double?) -> some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(bases.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: barWidth, height: height(i, time))
            }
        }
    }

    private func height(_ i: Int, _ time: Double?) -> CGFloat {
        guard let time else { return bases[i] * 0.7 }
        let s = 0.5 + 0.5 * sin(2 * .pi * (time / period) - phases[i] * 2 * .pi)
        return bases[i] * (0.45 + 0.55 * s)
    }
}

// MARK: - Custom slider (track + tick + boost coloring + knob)

struct GlassSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var showTick: Bool = false

    private let knob: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = range.upperBound - range.lowerBound
            let frac = max(0, min(1, (value - range.lowerBound) / span))
            let r = knob / 2
            let usable = max(1, w - knob)
            let knobX = r + frac * usable

            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border).frame(height: 4)
                Capsule().fill(Theme.accent)
                    .frame(width: max(4, knobX), height: 4)
                Circle().fill(Color.white)
                    .frame(width: knob, height: knob)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: knobX - r)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, (g.location.x - r) / usable))
                        value = range.lowerBound + f * span
                    }
            )
        }
        .frame(height: 16)
    }
}

// MARK: - Toggle switch (Settings)

struct ToggleSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.12)))
                .frame(width: 38, height: 21)
            Circle().fill(.white).frame(width: 17, height: 17)
                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.16), value: isOn)
        .onTapGesture { isOn.toggle() }
    }
}

private extension View {
    /// Shared dark-glass card chrome for Settings rows.
    func settingsCardStyle() -> some View {
        self
            .padding(.horizontal, 14).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surface)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
            .contentShape(Rectangle())
    }
}

// MARK: - Content

struct ContentView: View {
    @ObservedObject var manager: EngineManager
    var onLayoutChange: () -> Void = {}
    @State private var showAddMenu = false
    @State private var showOutputMenu = false
    @State private var showSettings = false
    @State private var confirmReset = false
    @State private var creditHover = false

    private var favoriteIDs: Set<String> { Set(manager.apps.filter { $0.isFavorite }.map { $0.id }) }

    // Panel heights (content + 5pt padding each side) for the accordion collapse.
    private static func panelHeight(_ count: Int) -> CGFloat {
        (count == 0 ? 38 : min(40 * 6, 40 * CGFloat(count))) + 10
    }
    private var outputPanelHeight: CGFloat { Self.panelHeight(manager.outputDevices.count) }
    private var addPanelHeight: CGFloat {
        Self.panelHeight(manager.runningApps.filter { !favoriteIDs.contains($0.id) }.count)
    }

    // Slide (move) transitions keep the panel opaque, so open AND close are
    // smooth with no text ghosting (a fade cross-dissolves text and looks rough).
    private let menuAnim = Animation.easeInOut(duration: 0.20)

    private func toggleAddMenu() {
        withAnimation(menuAnim) { showOutputMenu = false; showAddMenu.toggle() }
        onLayoutChange()
    }
    private func toggleOutputMenu() {
        withAnimation(menuAnim) { showAddMenu = false; showOutputMenu.toggle() }
        onLayoutChange()
    }
    private func closeMenus() {
        withAnimation(menuAnim) { showAddMenu = false; showOutputMenu = false }
        onLayoutChange()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showSettings {
                settingsHeader
                settingsContent
                Spacer(minLength: 10)
            } else {
                header
                statusBanner.padding(.horizontal, 16).padding(.bottom, 14)
                MasterRow(manager: manager, deviceMenuOpen: showOutputMenu, onDeviceTap: { toggleOutputMenu() })
                    .padding(.horizontal, 16).padding(.bottom, 8)
                // Accordion collapse (height rolls up toward the device name) — never
                // slides over the row above, so no text blending on close.
                outputMenuPanel
                    .frame(height: showOutputMenu ? outputPanelHeight : 0, alignment: .top)
                    .clipped()
                    .allowsHitTesting(showOutputMenu)   // collapsed panel must not eat taps
                    .padding(.horizontal, 16)
                    .padding(.bottom, showOutputMenu ? 8 : 0)
                sectionLabel
                appList
                addMenuPanel
                    .frame(height: showAddMenu ? addPanelHeight : 0, alignment: .bottom)
                    .clipped()
                    .allowsHitTesting(showAddMenu)       // collapsed panel must not eat taps
                    .padding(.horizontal, 16)
                    .padding(.top, showAddMenu ? 4 : 0)
                addFavorite
            }
            footer
            creditLine
        }
        .frame(width: 360)
        .background(panelBackground.contentShape(Rectangle()).onTapGesture { closeMenus() })
        .environment(\.colorScheme, .dark)
        .onChange(of: manager.apps.count) { _, _ in onLayoutChange() }
        .onChange(of: manager.outputDevices.count) { _, _ in onLayoutChange() }
        .onChange(of: manager.runningApps.count) { _, _ in onLayoutChange() }
        // Always reopen on the home (mixer) view, never stuck on Settings.
        .onDisappear { showSettings = false; showAddMenu = false; showOutputMenu = false }
    }

    // Output-device picker (same dark-glass style as Add Favorite)
    private var outputMenuPanel: some View {
        let devices = manager.outputDevices
        let rowHeight: CGFloat = 40
        let contentHeight: CGFloat = devices.isEmpty ? 38 : min(rowHeight * 6, rowHeight * CGFloat(devices.count))
        return Group {
            if devices.isEmpty {
                Text("No output devices found")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(devices) { dev in
                            OutputDeviceRow(device: dev, selected: dev.id == manager.outputDeviceID) {
                                manager.setOutputDevice(dev.id); closeMenus()
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 318, height: contentHeight)
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    // Header
    private var header: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 32, height: 32)
                .overlay(
                    DuckGlyph(bodyColor: .white, billColor: Theme.ink,
                              eyeColor: Theme.accent)
                        .frame(width: 23, height: 23)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text("Unduck Pro").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Text("LEVELS").font(.system(size: 10, weight: .heavy))
                    .tracking(1.2).foregroundStyle(Theme.ink2)
            }
            Spacer()
            Button {
                closeMenus()
                manager.refreshLaunchAtLogin()
                withAnimation(menuAnim) { showSettings = true }
                onLayoutChange()
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
                    .overlay(alignment: .topTrailing) {
                        if manager.updateAvailable {
                            Circle().fill(Theme.accent).frame(width: 8, height: 8)
                                .overlay(Circle().strokeBorder(Theme.bg, lineWidth: 1.5))
                                .offset(x: 2, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 13)
    }

    // Settings header — back arrow returns to the mixer ("LEVELS") view.
    private var settingsHeader: some View {
        HStack(spacing: 11) {
            Button {
                withAnimation(menuAnim) { showSettings = false }
                onLayoutChange()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 2) {
                Text("Unduck Pro").font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.ink)
                Text("SETTINGS").font(.system(size: 10, weight: .heavy))
                    .tracking(1.2).foregroundStyle(Theme.ink2)
            }
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 13)
    }

    // Settings body — Launch at login, Updates, Report a problem, Reset.
    private var settingsContent: some View {
        VStack(spacing: 10) {
            // Launch at login
            settingsCard {
                settingsIcon("power")
                settingsText("Launch at login", "Start Unduck Pro automatically when you log in")
                Spacer(minLength: 8)
                ToggleSwitch(isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { manager.setLaunchAtLogin($0) }
                ))
            }

            // Updates
            settingsCard {
                settingsIcon(manager.updateAvailable ? "arrow.down.circle.fill" : "checkmark.circle",
                             tint: manager.updateAvailable ? Theme.accent : Theme.ink2)
                if manager.updateAvailable {
                    settingsText("Update available",
                                 "Version \(manager.latestVersion ?? "") is ready — you have \(manager.currentVersion)")
                    Spacer(minLength: 8)
                    Button { openURL(manager.releasesURL) } label: {
                        Text("Download").font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                    }.buttonStyle(.plain)
                } else {
                    settingsText(manager.isCheckingUpdate ? "Checking for updates…" : "You're up to date",
                                 "Version \(manager.currentVersion)")
                    Spacer(minLength: 8)
                    Button { manager.checkForUpdates(force: true) } label: {
                        Text(manager.isCheckingUpdate ? "Checking…" : "Check")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.ink2)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
                    }
                    .buttonStyle(.plain)
                    .disabled(manager.isCheckingUpdate)
                }
            }

            // Report a problem
            Button { openURL(manager.issuesURL) } label: {
                HStack(spacing: 12) {
                    settingsIcon("ladybug.fill")
                    settingsText("Report a problem", "Open an issue on GitHub")
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
                }
                .settingsCardStyle()
            }.buttonStyle(.plain)

            // Reset volumes & favorites (tap twice to confirm)
            Button { handleReset() } label: {
                HStack(spacing: 12) {
                    settingsIcon("arrow.counterclockwise", tint: confirmReset ? Theme.red : Theme.accent)
                    settingsText(confirmReset ? "Tap again to confirm" : "Reset volumes & favorites",
                                 "Clears saved app volumes and starred apps")
                    Spacer(minLength: 8)
                }
                .settingsCardStyle()
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 6)
    }

    // Settings helpers
    private func settingsIcon(_ name: String, tint: Color = Theme.accent) -> some View {
        Image(systemName: name).font(.system(size: 15)).foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accentSoft))
    }
    private func settingsText(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func settingsCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 12) { content() }.settingsCardStyle()
    }
    private func openURL(_ s: String) {
        if let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
    private func handleReset() {
        if confirmReset {
            manager.resetVolumesAndFavorites()
            confirmReset = false
        } else {
            confirmReset = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmReset = false }
        }
    }

    // Status banner
    @ViewBuilder private var statusBanner: some View {
        if let error = manager.error {
            HStack(spacing: 11) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.red)
                Text(error.localizedDescription).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(11)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.red.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
        } else {
            let inCall = manager.isInCall
            HStack(spacing: 11) {
                EQBars(active: inCall && manager.isRunning, color: Theme.ink3,
                       bases: [7, 14, 9, 12], barWidth: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(inCall ? "On a call" : (manager.isRunning ? "Active" : "Starting…"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(inCall ? "Media stays loud — ducking paused"
                                : (manager.isRunning ? "Watching for calls" : "Getting ready"))
                        .font(.system(size: 11)).foregroundStyle(Theme.ink2)
                }
                Spacer()
            }
            .padding(.horizontal, 13).padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Theme.surface)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
            .opacity(manager.isRunning ? 1 : 0.55)
        }
    }

    // Section label
    private var sectionLabel: some View {
        HStack(spacing: 9) {
            Text("APP VOLUME").font(.system(size: 11, weight: .bold)).tracking(1.1).foregroundStyle(Theme.ink3)
            if !manager.apps.isEmpty {
                Text("\(manager.apps.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            Rectangle().fill(Theme.border).frame(height: 0.5)
        }
        .padding(.horizontal, 18).padding(.top, 11).padding(.bottom, 6)
    }

    // App list
    @ViewBuilder private var appList: some View {
        if manager.apps.isEmpty {
            Text("Nothing playing yet. Play some audio, or pick an app from “Add Favorite” below.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18).padding(.bottom, 8)
        } else {
            VStack(spacing: 0) {
                ForEach(manager.apps) { app in
                    AppRow(app: app, manager: manager)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
        }
    }

    // Add favorite — outlined accent button with a drop-up list
    private var addFavorite: some View {
        Button { toggleAddMenu() } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                Text("Add Favorite").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.accent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16).padding(.top, 9).padding(.bottom, 4)
    }

    private var addMenuPanel: some View {
        let available = manager.runningApps.filter { !favoriteIDs.contains($0.id) }
        let rowHeight: CGFloat = 40
        // Explicit height so the .overlay doesn't squash it to the button's height.
        let contentHeight: CGFloat = available.isEmpty
            ? 38
            : min(rowHeight * 6, rowHeight * CGFloat(available.count))

        return Group {
            if available.isEmpty {
                Text("No other apps to add")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(available) { item in
                            AddMenuRow(item: item) { manager.addFavorite(item); closeMenus() }
                        }
                    }
                }
            }
        }
        .frame(width: 318, height: contentHeight)
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    }

    // Footer — Quit sits in the bottom-right corner.
    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button {
                manager.stopEngine()
                NSApplication.shared.terminate(nil)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "power").font(.system(size: 12, weight: .semibold))
                    Text("Quit").font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.ink2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 15).padding(.top, 11).padding(.bottom, 8)
        .overlay(Rectangle().fill(Theme.border).frame(height: 0.5), alignment: .top)
    }

    // Developer credit → opens MrRockySL's GitHub profile.
    private var creditLine: some View {
        Button {
            if let url = URL(string: "https://github.com/MrRockySL") { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Text("Made by MrRockySL")
                Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(creditHover ? Theme.ink2 : Theme.ink3)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { creditHover = $0 }
        .padding(.bottom, 10)
    }

    // Panel background
    private var panelBackground: some View {
        Theme.bg
    }
}

// MARK: - Master output row

struct MasterRow: View {
    @ObservedObject var manager: EngineManager
    var deviceMenuOpen: Bool = false
    var onDeviceTap: () -> Void = {}

    var body: some View {
        VStack(spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "speaker.wave.2.fill").font(.system(size: 15)).foregroundStyle(Theme.accent)
                    .frame(width: 20)
                Button(action: onDeviceTap) {
                    HStack(spacing: 5) {
                        Text(manager.outputDeviceName).font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.ink).lineLimit(1)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.ink3)
                            .rotationEffect(.degrees(deviceMenuOpen ? 180 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Text("OUTPUT").font(.system(size: 9, weight: .heavy)).tracking(0.8)
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentSoft))
                Spacer(minLength: 4)
                Text("\(Int(manager.systemVolume * 100))%")
                    .font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(Theme.ink)
                Button { manager.toggleSystemMute() } label: {
                    Image(systemName: manager.systemMuted ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(manager.systemMuted ? Theme.red : Theme.ink2)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
                }
                .buttonStyle(.plain)
            }
            GlassSlider(value: Binding(get: { manager.systemVolume }, set: { manager.setSystemVolume($0) }),
                        range: 0...1)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.surface)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 0.5))
    }
}

// MARK: - App row

struct AppRow: View {
    let app: MixerApp
    @ObservedObject var manager: EngineManager

    private var liveVolume: Double {
        manager.apps.first(where: { $0.id == app.id })?.volume ?? app.volume
    }

    var body: some View {
        HStack(spacing: 11) {
            Button { manager.toggleFavorite(app) } label: {
                Image(systemName: app.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 15)).foregroundStyle(app.isFavorite ? Theme.accent : Theme.ink3)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(Theme.ink3)
                }
            }
            .frame(width: 34, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(app.isActive ? 1 : 0.55)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(app.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    if app.isActive {
                        EQBars(active: true, color: Theme.ink3, bases: [5, 10, 7],
                               phases: [0, 0.4, 0.65], barWidth: 2.2, spacing: 1.7)
                    }
                    Spacer(minLength: 4)
                    Text("\(Int(liveVolume * 100))%")
                        .font(.system(size: 12, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Theme.surface)
                        )
                }
                GlassSlider(value: Binding(get: { liveVolume }, set: { manager.setVolume($0, for: app) }),
                            range: 0...1.0)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 8)
    }
}

// MARK: - Add-favorite drop-up row

struct AddMenuRow: View {
    let item: RunningAppItem
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "app.dashed").resizable().foregroundStyle(Theme.ink3)
                    }
                }
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(item.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.surfaceHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

// MARK: - Output-device picker row

struct OutputDeviceRow: View {
    let device: AudioOutputDevice
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "speaker.wave.2.fill" : "speaker.wave.2")
                    .font(.system(size: 14)).foregroundStyle(selected ? Theme.accent : Theme.ink2)
                    .frame(width: 24)
                Text(device.name).font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(Theme.ink).lineLimit(1)
                Spacer(minLength: 6)
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 9).fill(hover ? Theme.surfaceHover : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
