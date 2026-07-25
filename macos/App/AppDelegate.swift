import AppKit
import EkoCore
import Foundation

@MainActor
private final class PanelOpenBroker {
    var action: () -> Void = {}
    func open() { action() }
}

@MainActor
private final class PublicationCoordinator {
    private let publisher: BonjourPublisher
    private let fingerprint: String
    private var port: UInt16?

    init(publisher: BonjourPublisher, fingerprint: String) {
        self.publisher = publisher
        self.fingerprint = fingerprint
    }

    func listenerReady(port: UInt16) {
        self.port = port
        publisher.publish(port: port, fingerprint: fingerprint)
    }

    func networkChanged(_ state: NetworkPathState) {
        guard state == .satisfied, let port else { return }
        publisher.publish(port: port, fingerprint: fingerprint)
    }
}

private final class DefaultsNotificationDeliveryPolicy: NotificationDeliveryPolicy, @unchecked Sendable {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allowsBanner(deviceID: String) -> Bool {
        !defaults.bool(forKey: "bannersPaused")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AppRuntime?
    private var statusController: StatusPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        do {
            let runtime = try AppRuntime()
            self.runtime = runtime
            let statusController = StatusPanelController(model: runtime.model, pairingBroker: runtime.pairingBroker)
            self.statusController = statusController
            runtime.openPanel = { [weak statusController] in statusController?.showPanel() }
            runtime.start()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "error.startup.title", defaultValue: "Eko could not start")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime?.stop()
    }

    @objc private func openSettingsFromMenu(_ sender: Any?) {
        statusController?.showSettings()
    }

    /// Build `NSApp.mainMenu`.
    ///
    /// There was none: `EkoMain.main()` assigned a delegate and called `run()`, and no
    /// MainMenu nib ships in the target. Two consequences, both severe for an
    /// `LSUIElement` app with no Dock icon.
    ///
    /// First, there was no user-reachable way to quit Eko — not from the panel, not from
    /// Settings, not from a menu. Activity Monitor or `killall`.
    ///
    /// Second, a nil `mainMenu` leaves `NSApplication` with nothing to dispatch key
    /// equivalents to, so ⌘Q, ⌘, and the whole editing set were inert. That is fatal for
    /// the two places this app deliberately invites text interaction: the feed's search
    /// field, and the four `.textSelection(.enabled)` sites — a user could select an OTP
    /// or a certificate fingerprint and then had no keyboard way to copy it. The Edit
    /// menu below is what makes ⌘C work in an accessory app; the items carry no target
    /// so they travel the responder chain to whatever field is first responder.
    ///
    /// Selectors are built by name rather than with `#selector` because these are
    /// responder-chain actions with no single owning type to reference.
    private func installMainMenu() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Eko"
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(
            title: String.localizedStringWithFormat(
                String(localized: "menu.about", defaultValue: "About %@"), appName
            ),
            action: Selector(("orderFrontStandardAboutPanel:")),
            keyEquivalent: ""
        )
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(
            title: String(localized: "menu.settings", defaultValue: "Settings…"),
            action: #selector(openSettingsFromMenu(_:)),
            keyEquivalent: ","
        )
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: String.localizedStringWithFormat(
                String(localized: "menu.hide", defaultValue: "Hide %@"), appName
            ),
            action: Selector(("hide:")),
            keyEquivalent: "h"
        ))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(
            title: String.localizedStringWithFormat(
                String(localized: "menu.quit", defaultValue: "Quit %@"), appName
            ),
            action: Selector(("terminate:")),
            keyEquivalent: "q"
        ))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: String(localized: "menu.edit", defaultValue: "Edit"))
        editMenu.addItem(NSMenuItem(title: String(localized: "menu.undo", defaultValue: "Undo"), action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: String(localized: "menu.redo", defaultValue: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: String(localized: "menu.cut", defaultValue: "Cut"), action: Selector(("cut:")), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: String(localized: "menu.copy", defaultValue: "Copy"), action: Selector(("copy:")), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: String(localized: "menu.paste", defaultValue: "Paste"), action: Selector(("paste:")), keyEquivalent: "v"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: String(localized: "menu.select_all", defaultValue: "Select All"), action: Selector(("selectAll:")), keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }
}

@MainActor
final class AppRuntime {
    let model: AppModel
    let pairingBroker: PairingApprovalBroker
    var openPanel: () -> Void {
        get { panelOpenBroker.action }
        set { panelOpenBroker.action = newValue }
    }

    private let panelOpenBroker: PanelOpenBroker
    private let store: EkoStore
    private let identity: DeviceIdentity
    private let diagnostics: DiagnosticsRecorder
    private let listener: TLSListener
    private let bonjour: BonjourPublisher
    private let bluetooth: BLEAdvertiser
    private let pathObserver: NetworkPathObserver
    private let notificationCoordinator: NotificationCoordinator
    private let publicationCoordinator: PublicationCoordinator
    private let backgroundPruner: NSBackgroundActivityScheduler

    init() throws {
        let panelOpenBroker = PanelOpenBroker()
        self.panelOpenBroker = panelOpenBroker
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        store = try EkoStore(path: applicationSupport.appendingPathComponent("Eko/Eko.sqlite").path)
        identity = try KeychainIdentityManager().loadOrCreateIdentity()
        diagnostics = DiagnosticsRecorder()
        pairingBroker = PairingApprovalBroker()
        let pairingMode = PairingModeController()
        let clipboard = ClipboardController()
        let login = LaunchAtLoginService()
        model = AppModel(
            store: store,
            identity: identity,
            pairingMode: pairingMode,
            pairingBroker: pairingBroker,
            clipboard: clipboard,
            loginService: login,
            diagnostics: diagnostics
        )

        let notificationStrings = NotificationStrings(
            copyCodeAction: String(localized: "notification.copy_code", defaultValue: "Copy code"),
            backlogTitle: { name in
                String.localizedStringWithFormat(
                    String(localized: "notification.backlog.title", defaultValue: "%@ reconnected"),
                    name
                )
            },
            backlogBody: { notifications, codes in
                String.localizedStringWithFormat(
                    String(localized: "notification.backlog.body", defaultValue: "%d missed notifications, %d codes"),
                    notifications,
                    codes
                )
            }
        )
        notificationCoordinator = NotificationCoordinator(
            store: store,
            clipboard: clipboard,
            strings: notificationStrings,
            deliveryPolicy: DefaultsNotificationDeliveryPolicy(),
            openPanel: { [weak model] deviceID, key in
                await model?.focus(deviceID: deviceID, key: key)
                await panelOpenBroker.open()
            }
        )
        let sink = AppSessionSink(model: model, store: store, notifications: notificationCoordinator, diagnostics: diagnostics)
        let sessions = SessionManager(
            store: store,
            localIdentity: identity,
            macName: Host.current().localizedName ?? "Mac",
            pairingMode: pairingMode,
            sink: sink,
            pairingApproval: { [weak pairingBroker] pending in
                await pairingBroker?.request(pending) ?? false
            }
        )
        model.attach(sessionManager: sessions)
        let authorizer = StorePeerAuthorizer(store: store, pairingMode: pairingMode)
        listener = TLSListener(
            identity: identity,
            authorizer: authorizer,
            sessionManager: sessions,
            stateHandler: { [weak model] state in
                Task { @MainActor in model?.setListenerState(state) }
            }
        )
        let bonjour = BonjourPublisher { [weak model] state in model?.setBonjourState(state) }
        self.bonjour = bonjour
        let publicationCoordinator = PublicationCoordinator(publisher: bonjour, fingerprint: identity.fingerprint)
        self.publicationCoordinator = publicationCoordinator
        bluetooth = BLEAdvertiser { [weak model] state in model?.setBluetoothState(state) }
        pathObserver = NetworkPathObserver { [weak model] state in
            Task { @MainActor in
                model?.setNetworkPathState(state)
                publicationCoordinator.networkChanged(state)
            }
        }
        backgroundPruner = NSBackgroundActivityScheduler(identifier: "com.eko.mac.history-prune")
        backgroundPruner.repeats = true
        backgroundPruner.interval = 6 * 60 * 60
        backgroundPruner.tolerance = 60 * 60
    }

    func start() {
        bluetooth.start()
        pathObserver.start()
        Task {
            do {
                try await notificationCoordinator.configure()
            } catch {
                await diagnostics.record(.warning, category: "notifications", message: error.localizedDescription)
            }
        }
        Task {
            do {
                let preferred = UInt16(await MainActor.run { model.configuredPort })
                let port = try await listener.startWithPortFallback(preferredPort: preferred)
                await publicationCoordinator.listenerReady(port: port)
                await diagnostics.record(.info, category: "listener", message: "TLS listener ready on port \(port)")
            } catch {
                await MainActor.run { self.model.setFatalError(error) }
                await diagnostics.record(.error, category: "listener", message: error.localizedDescription)
            }
        }
        let store = self.store
        let model = self.model
        let diagnostics = self.diagnostics
        backgroundPruner.schedule { completion in
            Task {
                do {
                    let settings = await MainActor.run { (model.retentionDays, model.retentionCount) }
                    try store.prune(retentionDays: settings.0, maximumNotificationsPerDevice: settings.1)
                    completion(.finished)
                } catch {
                    await diagnostics.record(.warning, category: "retention", message: error.localizedDescription)
                    completion(.deferred)
                }
            }
        }
    }

    func stop() {
        listener.stop()
        bonjour.stop()
        bluetooth.stop()
        pathObserver.stop()
        backgroundPruner.invalidate()
    }
}
