import AppKit
import SwiftUI

/// Owns the menu-bar item and Unduck Pro's dropdown window.
///
/// `MenuBarExtra(.window)` adds its own system Liquid Glass sheet on newer
/// macOS versions. That sheet can remain visible above and below a custom
/// background and makes the panel look double-layered. This transparent,
/// borderless panel draws exactly one clipped glass surface instead.
@MainActor
final class DuckAudioAppDelegate: NSObject, NSApplicationDelegate {
    private let manager = EngineManager()
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(manager: manager)
        manager.startEngine()
        manager.checkForUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) {
        manager.stopEngine()
    }
}

/// A custom dropdown modeled as one continuous rounded glass card.
@MainActor
final class StatusBarController: NSObject {
    private let manager: EngineManager
    private let panel: NSPanel
    private let container = NSView()
    private let hostingView: FirstMouseHostingView<MenuBarPanelRoot>
    private var statusItem: NSStatusItem?
    private var eventMonitors: [Any] = []
    private var lastContentSize = CGSize.zero
    private var lastCloseAt: Date = .distantPast
    private let reopenSuppression: TimeInterval = 0.25

    init(manager: EngineManager) {
        self.manager = manager

        hostingView = FirstMouseHostingView(
            rootView: MenuBarPanelRoot(manager: manager, sessionID: UUID())
        )

        panel = KeyablePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)

        container.wantsLayer = true
        container.layer?.cornerRadius = 26
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.frame = container.bounds
        blur.autoresizingMask = [.width, .height]
        container.addSubview(blur)

        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        hostingView.sizingOptions = [.intrinsicContentSize]
        container.addSubview(hostingView)
        panel.contentView = container

        super.init()

        installStatusItem()
    }

    isolated deinit {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarGlyph.image
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        statusItem = item
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            closePanel()
            return
        }
        guard Date().timeIntervalSince(lastCloseAt) > reopenSuppression else { return }
        openPanel()
    }

    private func openPanel() {
        guard statusItem?.button?.window != nil else { return }

        // Recreate the view identity each time so temporary UI state (Settings
        // and open accordion menus) always resets when the panel reopens.
        hostingView.rootView = MenuBarPanelRoot(
            manager: manager,
            sessionID: UUID(),
            isActive: true,
            onLayoutChange: { [weak self] in self?.requestContentSizeUpdate() }
        )
        manager.menuDidOpen()
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()

        let fitting = normalizedSize(hostingView.fittingSize)
        lastContentSize = fitting
        positionPanel(for: fitting)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        statusItem?.button?.highlight(true)
        installEventMonitors()
    }

    private func closePanel() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        lastCloseAt = Date()
        statusItem?.button?.highlight(false)
        removeEventMonitors()
        manager.menuDidClose()
        // Tear the SwiftUI content down so nothing keeps animating off-screen.
        // `openPanel()` rebuilds it from scratch on every open anyway.
        hostingView.rootView = MenuBarPanelRoot(
            manager: manager,
            sessionID: UUID(),
            isActive: false
        )
    }

    private func contentSizeDidChange(_ rawSize: CGSize) {
        let size = normalizedSize(rawSize)
        guard size.width > 1, size.height > 1 else { return }
        guard size != lastContentSize else { return }
        lastContentSize = size
        if panel.isVisible { positionPanel(for: size) }
    }

    /// SwiftUI state changes update their ideal layout before the next main-run
    /// loop turn. Read fittingSize then and resize the native panel to match.
    private func requestContentSizeUpdate() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.panel.isVisible else { return }
            self.hostingView.invalidateIntrinsicContentSize()
            self.hostingView.layoutSubtreeIfNeeded()
            self.contentSizeDidChange(self.hostingView.fittingSize)
        }
    }

    private func normalizedSize(_ size: CGSize) -> CGSize {
        CGSize(width: max(360, ceil(size.width)), height: max(1, ceil(size.height)))
    }

    /// Keeps the panel's top edge anchored beneath the menu-bar item while its
    /// SwiftUI content grows or collapses.
    private func positionPanel(for size: CGSize) {
        guard let button = statusItem?.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = anchor.midX - size.width / 2
        var y = anchor.minY - 6 - size.height

        if let screen = buttonWindow.screen {
            let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
            x = min(max(x, bounds.minX), bounds.maxX - size.width)
            y = max(y, bounds.minY)
        }
        panel.setFrame(NSRect(origin: CGPoint(x: x, y: y), size: size), display: true)
    }

    private func installEventMonitors() {
        guard eventMonitors.isEmpty else { return }

        let global = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
            handler: { [weak self] _ in
                Task { @MainActor in self?.closePanel() }
            }
        )
        if let global {
            eventMonitors.append(global)
        }

        let local = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
            handler: { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown {
                    if event.keyCode == 53 { self.closePanel(); return nil }
                    return event
                }
                let clickedWindow = event.window
                let inPanel = clickedWindow === self.panel
                    || (clickedWindow.map { self.panel.childWindows?.contains($0) ?? false } ?? false)
                    || (clickedWindow.map { String(describing: type(of: $0)).contains("Popover") } ?? false)
                let onStatusButton = clickedWindow === self.statusItem?.button?.window
                if !inPanel && !onStatusButton { self.closePanel() }
                return event
            }
        )
        if let local {
            eventMonitors.append(local)
        }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct MenuBarPanelRoot: View {
    @ObservedObject var manager: EngineManager
    let sessionID: UUID
    /// False while the panel is closed. Ordering an `NSPanel` out does not stop
    /// its hosting view from laying out: the mixer's `EQBars` use
    /// `TimelineView(.animation)`, so the whole panel was re-running a full
    /// SwiftUI layout pass every display frame while nobody could see it. That
    /// burned ~20% CPU continuously and added needless scheduling pressure to
    /// the audio render queues. Swapping in an inert view stops it dead.
    var isActive: Bool = true
    var onLayoutChange: () -> Void = {}

    var body: some View {
        if isActive {
            activeBody
        } else {
            Color.clear.frame(width: 360, height: 1)
        }
    }

    private var activeBody: some View {
        ContentView(manager: manager, onLayoutChange: onLayoutChange)
            .id(sessionID)
            // The hosting view is otherwise allowed to compress this VStack to
            // the panel's previous height. Keeping its ideal vertical size lets
            // the fitting-size callback grow the actual NSPanel when an accordion
            // opens, instead of pushing the header above the clipped window.
            .fixedSize(horizontal: false, vertical: true)
            .preferredColorScheme(.dark)
    }
}
