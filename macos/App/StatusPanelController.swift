import AppKit
import Combine
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Escape dismisses the panel.
    ///
    /// AppKit routes Escape to `cancelOperation(_:)` along the responder chain; nothing
    /// implemented it, so the key did nothing anywhere in the feed. A menu-bar popover
    /// that cannot be dismissed from the keyboard is the wrong shape for an app whose
    /// whole value is speed.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}

/// The inputs the status item actually renders, so a redraw can be skipped when none of
/// them changed. `AppModel.objectWillChange` fires on every feed delivery, every
/// connection-state change and every gap refresh — thousands of times during a backlog
/// replay — and almost none of those change the glyph.
private struct StatusDescriptor: Equatable {
    var bannersPaused: Bool
    var disconnected: Int
    var syncing: Bool
    var hasCode: Bool
}

@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let pairingBroker: PairingApprovalBroker
    private let statusItem: NSStatusItem
    private let panel: KeyablePanel
    private let settingsController: SettingsWindowController
    private var cancellables: Set<AnyCancellable> = []
    private var statusImages: [String: NSImage] = [:]
    private var lastDescriptor: StatusDescriptor?
    private var codeExpiryTimer: Timer?

    init(model: AppModel, pairingBroker: PairingApprovalBroker) {
        self.model = model
        self.pairingBroker = pairingBroker
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        settingsController = SettingsWindowController(model: model)
        super.init()

        configureStatusItem()
        configurePanel()
        observeStatus()
    }

    func showPanel() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        model.panelVisibilityChanged(true)
    }

    @objc private func statusItemClicked() {
        // Right- and control-click open the menu; left-click toggles the panel. Without
        // the menu there is no way to quit Eko at all: LSUIElement means no Dock icon,
        // and nothing in the panel or Settings terminates the app.
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp ||
            (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true)
        if isSecondary {
            presentStatusMenu()
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
            statusItem.button?.highlight(false)
            model.panelVisibilityChanged(false)
        } else {
            showPanel()
        }
    }

    private func presentStatusMenu() {
        let menu = NSMenu()

        let open = NSMenuItem(
            title: String(localized: "menu.open_panel", defaultValue: "Open Eko"),
            action: #selector(menuOpenPanel),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: String(localized: "settings.pause_banners", defaultValue: "Pause banners"),
            action: #selector(menuTogglePause),
            keyEquivalent: ""
        )
        pause.target = self
        pause.state = model.bannersPaused ? .on : .off
        menu.addItem(pause)

        let settings = NSMenuItem(
            title: String(localized: "settings.open", defaultValue: "Open settings"),
            action: #selector(menuOpenSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        // nil target: goes up the responder chain to NSApp, which implements terminate:.
        let quit = NSMenuItem(
            title: String(localized: "menu.quit", defaultValue: "Quit Eko"),
            action: Selector(("terminate:")),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        // Assign, click, unassign: leaving a menu attached would replace the left-click
        // action entirely, and left-click must still toggle the panel.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuOpenPanel() { showPanel() }
    @objc private func menuOpenSettings() { showSettings() }
    @objc private func menuTogglePause() { model.bannersPaused.toggle() }

    func showSettings() {
        settingsController.show()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = statusImage(symbol: "iphone.radiowaves.left.and.right")
        button.imagePosition = .imageOnly
        button.toolTip = String(localized: "status.tooltip", defaultValue: "Eko notifications")
        button.setAccessibilityLabel(String(localized: "status.accessibility", defaultValue: "Eko notification panel"))
    }

    private func configurePanel() {
        panel.delegate = self
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // .closable gives a close button and .resizable on a titled window gives a zoom
        // button; combined with .fullSizeContentView they render directly over the
        // BrandMark and the wordmark in the 48pt header. Traffic lights on a menu-bar
        // popover's own logo is the most obvious "unfinished port" tell on macOS.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        // .floating, not .popUpMenu, for the pinned case. Unpinned, windowDidResignKey
        // orders the panel out before Settings takes key, so the two never compete. But
        // with "Keep panel open" on, that guard returns early and a .popUpMenu panel
        // (level 101) stays above the Settings window (.normal, level 0) and above the
        // app-modal NSSavePanel the diagnostics export puts up. .floating is also the
        // conventional level for a menu-bar popover.
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 380, height: 460)
        panel.maxSize = NSSize(width: 520, height: 900)
        panel.contentView = NSHostingView(rootView: PanelRootView(
            model: model,
            pairingBroker: pairingBroker,
            openSettings: { [weak self] in self?.settingsController.show() }
        ))
    }

    private func observeStatus() {
        // One hop, throttled, instead of `receive(on: RunLoop.main)` wrapping a
        // `DispatchQueue.main.async`. objectWillChange fires on every feed delivery,
        // every connection-state change, every per-event gap refresh and the 60s clock
        // tick — thousands of times during a 2'000-event replay — and each run used to
        // scan up to 400 notifications and build a fresh NSImage. Throttling on
        // DispatchQueue.main also means the sink observes post-change values, which is
        // what the inner async hop was really compensating for.
        model.objectWillChange
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.updateStatusItem() }
            .store(in: &cancellables)
    }

    private func currentDescriptor() -> StatusDescriptor {
        let connected = model.connectionStates.values.filter { $0 == .online }.count
        let disconnected = max(0, model.devices.filter { $0.pairingState == .confirmed }.count - connected)
        // Hoisted out of the predicate: this used to allocate a Date and add a
        // TimeInterval once per element, for every element.
        let cutoff = Date().addingTimeInterval(-Self.codeFreshness)
        return StatusDescriptor(
            bannersPaused: model.bannersPaused,
            disconnected: disconnected,
            syncing: model.connectionStates.values.contains(.synchronizing),
            hasCode: model.notifications.contains { $0.otpCode != nil && $0.receivedAt > cutoff }
        )
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let descriptor = currentDescriptor()
        scheduleCodeExpiry(hasCode: descriptor.hasCode)
        guard descriptor != lastDescriptor else { return }
        lastDescriptor = descriptor

        if descriptor.bannersPaused {
            button.image = statusImage(symbol: "bell.slash")
            button.toolTip = String(localized: "status.banners_paused", defaultValue: "Notification banners are paused")
        } else if descriptor.disconnected > 0 {
            button.image = statusImage(symbol: "iphone.slash")
            button.toolTip = String.localizedStringWithFormat(
                String(localized: "status.disconnected", defaultValue: "%d phones disconnected"),
                descriptor.disconnected
            )
        } else if descriptor.syncing {
            button.image = statusImage(symbol: "arrow.triangle.2.circlepath.iphone")
            button.toolTip = String(localized: "status.syncing", defaultValue: "Eko is syncing")
        } else if descriptor.hasCode {
            button.image = statusImage(symbol: "iphone.badge.checkmark")
            button.toolTip = String(localized: "status.code_available", defaultValue: "A verification code is available")
        } else {
            button.image = statusImage(symbol: "iphone.radiowaves.left.and.right")
            button.toolTip = String(localized: "status.tooltip", defaultValue: "Eko notifications")
        }
        button.setAccessibilityValue(button.toolTip)
    }

    /// Make the "a code is available" state expire on its own.
    ///
    /// `hasCode` is a time predicate, but the only thing that recomputed it was an
    /// unrelated model change. With the panel closed the 60-second clock is stopped too,
    /// so on a quiet Mac the checkmark glyph stuck indefinitely — long after the code
    /// was useless. One timer, armed only while the state is on.
    private func scheduleCodeExpiry(hasCode: Bool) {
        codeExpiryTimer?.invalidate()
        codeExpiryTimer = nil
        guard hasCode else { return }
        codeExpiryTimer = Timer.scheduledTimer(withTimeInterval: Self.codeFreshness, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.updateStatusItem() }
        }
    }

    private func statusImage(symbol: String) -> NSImage? {
        if let cached = statusImages[symbol] { return cached }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        // The status slot is squareLength but these symbols have very different aspect
        // ratios, and without a configuration the wide ones render pinched.
        let configured = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        ) ?? image
        configured?.isTemplate = true
        if let configured { statusImages[symbol] = configured }
        return configured
    }

    private static let codeFreshness: TimeInterval = 60

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? .zero
        var origin = NSPoint(
            x: buttonFrame.midX - panel.frame.width / 2,
            y: buttonFrame.minY - panel.frame.height - 6
        )
        origin.x = min(max(origin.x, visibleFrame.minX + 8), visibleFrame.maxX - panel.frame.width - 8)
        origin.y = max(origin.y, visibleFrame.minY + 8)
        panel.setFrameOrigin(origin)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard !model.panelPinned, settingsController.window?.isKeyWindow != true else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        model.panelVisibilityChanged(false)
    }

    func windowWillClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        model.panelVisibilityChanged(false)
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "settings.title", defaultValue: "Eko Settings")
        window.minSize = NSSize(width: 640, height: 480)
        window.center()
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
