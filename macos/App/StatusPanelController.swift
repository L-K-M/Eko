import AppKit
import Combine
import SwiftUI

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let pairingBroker: PairingApprovalBroker
    private let statusItem: NSStatusItem
    private let panel: KeyablePanel
    private let settingsController: SettingsWindowController
    private var cancellables: Set<AnyCancellable> = []
    private var codeExpiryRefresh: Task<Void, Never>?

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
        model.panelVisibilityChanged(true)
    }

    @objc private func togglePanel() {
        // Right-click gets the housekeeping menu. Without it the app is
        // unquittable: activation policy is .accessory (no Dock icon) and a
        // menu-bar-only app has no visible main menu.
        if NSApp.currentEvent.map({ $0.type == .rightMouseUp || $0.modifierFlags.contains(.control) }) == true {
            showStatusMenu()
            return
        }
        if panel.isVisible {
            panel.orderOut(nil)
            model.panelVisibilityChanged(false)
        } else {
            showPanel()
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        let settingsItem = NSMenuItem(
            title: String(localized: "settings.open", defaultValue: "Open settings"),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: String(localized: "app.quit", defaultValue: "Quit Eko"),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
        // The reliable status-item presentation: attach the menu, synthesize a
        // click so AppKit anchors and tracks it natively, then detach so the
        // next plain click toggles the panel again.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openSettingsFromMenu() {
        settingsController.show()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePanel)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.image = statusImage(symbol: "iphone.radiowaves.left.and.right")
        button.imagePosition = .imageOnly
        button.toolTip = String(localized: "status.tooltip", defaultValue: "Eko notifications")
        button.setAccessibilityLabel(String(localized: "status.accessibility", defaultValue: "Eko notification panel"))
    }

    private func configurePanel() {
        panel.delegate = self
        // NSWindow releases itself on close by default; this panel is closable,
        // strongly held, and reshown on every status-item click, so the default
        // is a use-after-free on the click after the close button.
        panel.isReleasedWhenClosed = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
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
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateStatusItem() }
            }
            .store(in: &cancellables)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let connected = model.connectionStates.values.filter { $0 == .online }.count
        let disconnected = max(0, model.devices.filter { $0.pairingState == .confirmed }.count - connected)
        let syncing = model.connectionStates.values.contains(.synchronizing)
        let hasCode = model.notifications.contains { $0.otpCode != nil && $0.receivedAt > Date().addingTimeInterval(-60) }

        if model.bannersPaused {
            button.image = statusImage(symbol: "bell.slash")
            button.toolTip = String(localized: "status.banners_paused", defaultValue: "Notification banners are paused")
        } else if disconnected > 0 {
            button.image = statusImage(symbol: "iphone.slash")
            button.toolTip = String.localizedStringWithFormat(
                String(localized: "status.disconnected", defaultValue: "%d phones disconnected"),
                disconnected
            )
        } else if syncing {
            button.image = statusImage(symbol: "arrow.triangle.2.circlepath.iphone")
            button.toolTip = String(localized: "status.syncing", defaultValue: "Eko is syncing")
        } else if hasCode {
            button.image = statusImage(symbol: "iphone.badge.checkmark")
            button.toolTip = String(localized: "status.code_available", defaultValue: "A verification code is available")
        } else {
            button.image = statusImage(symbol: "iphone.radiowaves.left.and.right")
            button.toolTip = String(localized: "status.tooltip", defaultValue: "Eko notifications")
        }
        button.setAccessibilityValue(button.toolTip)

        // The code badge is time-based, but this method only runs on model
        // changes — without a scheduled refresh the icon sticks on "code
        // available" after the 60-second window lapses.
        codeExpiryRefresh?.cancel()
        codeExpiryRefresh = nil
        if hasCode,
           let newest = model.notifications.compactMap({ $0.otpCode != nil ? $0.receivedAt : nil }).max() {
            let delay = newest.addingTimeInterval(60).timeIntervalSinceNow
            codeExpiryRefresh = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, delay)))
                guard !Task.isCancelled else { return }
                self?.updateStatusItem()
            }
        }
    }

    private func statusImage(symbol: String) -> NSImage? {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: nil)
        image?.isTemplate = true
        return image
    }

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
        // AppKit resigns the old key window before the new one becomes key, so
        // checking synchronously always sees the settings window as not-key and
        // closes the panel whenever settings opens. Decide one runloop later,
        // when NSApp.keyWindow reflects the destination.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.model.panelPinned else { return }
            guard !self.panel.isKeyWindow, NSApp.keyWindow !== self.settingsController.window else { return }
            self.panel.orderOut(nil)
            self.model.panelVisibilityChanged(false)
        }
    }

    func windowWillClose(_ notification: Notification) {
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
