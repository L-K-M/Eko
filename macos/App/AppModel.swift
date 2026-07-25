import AppKit
import Combine
import EkoCore
import Foundation
import UniformTypeIdentifiers

enum PanelRoute: String, CaseIterable, Identifiable {
    case feed
    case pairing

    var id: String { rawValue }
}

struct PairingDisplay: Equatable {
    let host: String
    let port: UInt16
    let fingerprint: String
    let token: String
    let expiresAt: Date
    let qrPayload: String
}

@MainActor
final class PairingApprovalBroker: ObservableObject {
    @Published private(set) var pending: PendingPairing?
    private var continuation: CheckedContinuation<Bool, Never>?
    private var expiryTask: Task<Void, Never>?

    func request(_ pairing: PendingPairing) async -> Bool {
        continuation?.resume(returning: false)
        expiryTask?.cancel()
        pending = pairing
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.expiryTask = Task { [weak self] in
                let delay = max(0, pairing.expiresAt.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.resolve(false)
            }
        }
    }

    func resolve(_ approved: Bool) {
        expiryTask?.cancel()
        expiryTask = nil
        let continuation = continuation
        self.continuation = nil
        pending = nil
        continuation?.resume(returning: approved)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var devices: [Device] = []
    @Published private(set) var notifications: [CurrentNotification] = []
    @Published private(set) var gaps: [GapSpan] = []
    @Published private(set) var appPreferences: [AppPreference] = []
    @Published private(set) var connectionStates: [String: DeviceConnectionState] = [:]
    @Published var searchText = "" {
        didSet { scheduleFeedObservation() }
    }
    @Published var selectedDeviceID: String? {
        didSet { restartFeedObservation() }
    }
    @Published var codesOnly = false {
        didSet { restartFeedObservation() }
    }
    @Published var route: PanelRoute = .feed
    @Published private(set) var pairingDisplay: PairingDisplay?
    @Published private(set) var listenerState: TLSListenerState = .stopped
    @Published private(set) var bonjourState: BonjourPublicationState = .stopped
    @Published private(set) var bluetoothState: BLEAdvertisingState = .stopped
    @Published private(set) var networkPathState: NetworkPathState = .unsatisfied
    @Published private(set) var diagnosticsEvents: [DiagnosticEvent] = []
    @Published private(set) var boundPort: UInt16?
    @Published var panelPinned = false
    @Published var focusedNotificationID: String?
    @Published var includeContentInDiagnostics = false
    @Published var clipboardAutoClear: Bool {
        didSet { defaults.set(clipboardAutoClear, forKey: Keys.clipboardAutoClear) }
    }
    @Published var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Keys.retentionDays) }
    }
    @Published var retentionCount: Int {
        didSet { defaults.set(retentionCount, forKey: Keys.retentionCount) }
    }
    @Published var configuredPort: Int {
        didSet {
            let clamped = min(max(configuredPort, 1_024), 65_535)
            if configuredPort != clamped {
                configuredPort = clamped
                return
            }
            defaults.set(configuredPort, forKey: Keys.listenerPort)
        }
    }
    @Published var bannersPaused: Bool {
        didSet { defaults.set(bannersPaused, forKey: Keys.bannersPaused) }
    }
    @Published var groupByDevice: Bool {
        didSet { defaults.set(groupByDevice, forKey: Keys.groupByDevice) }
    }
    @Published private(set) var launchAtLoginState: LaunchAtLoginState
    @Published private(set) var fatalError: String?
    @Published private(set) var now = Date()

    let store: EkoStore
    let identity: DeviceIdentity
    let pairingMode: PairingModeController
    let pairingBroker: PairingApprovalBroker

    private let clipboard: ClipboardController
    private let loginService: any LaunchAtLoginControlling
    private let diagnostics: DiagnosticsRecorder
    private let defaults: UserDefaults
    private var sessionManager: SessionManager?
    private var feedTask: Task<Void, Never>?
    private var searchDebounceTask: Task<Void, Never>?
    private var devicesTask: Task<Void, Never>?
    private var preferencesTask: Task<Void, Never>?
    private var relativeTimeTask: Task<Void, Never>?
    private var pairingExpiryTask: Task<Void, Never>?
    private var panelVisible = true

    private enum Keys {
        static let clipboardAutoClear = "clipboardAutoClear"
        static let retentionDays = "retentionDays"
        static let retentionCount = "retentionCount"
        static let listenerPort = "listenerPort"
        static let bannersPaused = "bannersPaused"
        static let groupByDevice = "groupByDevice"
    }

    init(
        store: EkoStore,
        identity: DeviceIdentity,
        pairingMode: PairingModeController,
        pairingBroker: PairingApprovalBroker,
        clipboard: ClipboardController,
        loginService: any LaunchAtLoginControlling,
        diagnostics: DiagnosticsRecorder,
        defaults: UserDefaults = .standard
    ) {
        self.store = store
        self.identity = identity
        self.pairingMode = pairingMode
        self.pairingBroker = pairingBroker
        self.clipboard = clipboard
        self.loginService = loginService
        self.diagnostics = diagnostics
        self.defaults = defaults
        self.clipboardAutoClear = defaults.object(forKey: Keys.clipboardAutoClear) as? Bool ?? true
        self.retentionDays = max(1, defaults.object(forKey: Keys.retentionDays) as? Int ?? 7)
        self.retentionCount = max(100, defaults.object(forKey: Keys.retentionCount) as? Int ?? 5_000)
        let storedPort = defaults.object(forKey: Keys.listenerPort) as? Int ?? 48_808
        self.configuredPort = min(max(storedPort, 1_024), 65_535)
        self.bannersPaused = defaults.bool(forKey: Keys.bannersPaused)
        self.groupByDevice = defaults.bool(forKey: Keys.groupByDevice)
        self.launchAtLoginState = loginService.state()
        startObservations()
    }

    func attach(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
    }

    func setListenerState(_ state: TLSListenerState) {
        listenerState = state
        if case .ready(let port, _) = state { boundPort = port }
    }

    func setBonjourState(_ state: BonjourPublicationState) {
        bonjourState = state
    }

    func setBluetoothState(_ state: BLEAdvertisingState) {
        bluetoothState = state
    }

    func setNetworkPathState(_ state: NetworkPathState) {
        networkPathState = state
    }

    func setConnectionState(deviceID: String, state: DeviceConnectionState) {
        connectionStates[deviceID] = state
    }

    func setFatalError(_ error: Error) {
        fatalError = error.localizedDescription
    }

    /// Called from the OTP banner's default action, so it sits directly in front of the
    /// app's most latency-sensitive interaction: click the banner, panel appears.
    ///
    /// It used to run the 500-row feed query — correlated OTP subquery and all —
    /// *synchronously on the main thread*, then linearly search the result for one key,
    /// before the panel could open. The query now runs off the main actor and only the
    /// result assignment hops back.
    func focus(deviceID: String, key: String) async {
        route = .feed
        selectedDeviceID = deviceID
        let store = self.store
        let match = await Task.detached(priority: .userInitiated) {
            try? store.notifications(query: FeedQuery(deviceID: deviceID, limit: 500))
                .first(where: { $0.key == key })
        }.value
        if let match {
            focusedNotificationID = match.id
        }
    }

    func beginPairing() {
        guard let port = boundPort else {
            setFatalError(EkoCoreError.transportClosed)
            return
        }
        do {
            let invitation = try pairingMode.activate()
            let host = Self.localHostName
            let object: [String: Any] = [
                "host": host,
                "port": Int(port),
                "certFingerprint": identity.fingerprint,
                "token": invitation.token,
                "proto": 1,
            ]
            let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            guard let payload = String(data: data, encoding: .utf8) else { throw EkoCoreError.invalidData("pairing QR is not UTF-8") }
            pairingDisplay = PairingDisplay(
                host: host,
                port: port,
                fingerprint: identity.fingerprint,
                token: invitation.token,
                expiresAt: invitation.expiresAt,
                qrPayload: payload
            )
            pairingExpiryTask?.cancel()
            pairingExpiryTask = Task { [weak self] in
                let delay = max(0, invitation.expiresAt.timeIntervalSinceNow)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.endPairing()
            }
            route = .pairing
        } catch {
            setFatalError(error)
        }
    }

    func endPairing() {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingMode.deactivate()
        pairingDisplay = nil
        pairingBroker.resolve(false)
        route = .feed
    }

    // EkoStore sets busyMode = .timeout(5), so a pool.write from the main actor can
    // block the UI for up to five seconds behind an in-flight ingest write — which is
    // most likely exactly when the user is reaching for a code. These three writes now
    // run off the main actor; none of them feeds back into the view except through the
    // store's own observations.
    func copyCode(_ code: String, deviceID: String) {
        clipboard.copy(code, clearAfter: clipboardAutoClear ? 120 : nil)
        let store = self.store
        Task.detached(priority: .utility) {
            try? store.markOTPCopied(deviceID: deviceID, code: code)
        }
    }

    func copyText(_ text: String) {
        clipboard.copy(text, clearAfter: nil)
    }

    func dismiss(_ notification: CurrentNotification) {
        guard notification.isActive else { return }
        Task {
            do {
                try await sessionManager?.dismiss(deviceID: notification.deviceID, key: notification.key)
            } catch {
                await diagnostics.record(.warning, category: "dismiss", message: error.localizedDescription)
            }
        }
    }

    func toggleStar(_ notification: CurrentNotification) {
        let store = self.store
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try store.setStarred(
                    deviceID: notification.deviceID,
                    generation: notification.generation,
                    key: notification.key,
                    starred: !notification.isStarred
                )
            } catch {
                await self?.setFatalError(error)
            }
        }
    }

    func updatePreference(_ preference: AppPreference) {
        let store = self.store
        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try store.setAppPreference(
                    deviceID: preference.deviceID,
                    appPackage: preference.appPackage,
                    bannerMode: preference.bannerMode,
                    autoCopyOTP: preference.autoCopyOTP,
                    soundEnabled: preference.soundEnabled
                )
            } catch {
                await self?.setFatalError(error)
            }
        }
    }

    func requestUnpair(_ device: Device) {
        Task {
            do {
                try await sessionManager?.requestUnpair(deviceID: device.id)
            } catch {
                await diagnostics.record(.error, category: "unpair", message: error.localizedDescription)
            }
        }
    }

    func forgetWithoutNotifying(_ device: Device) {
        Task {
            do {
                try await sessionManager?.forgetPeer(deviceID: device.id)
            } catch {
                await diagnostics.record(.error, category: "unpair", message: error.localizedDescription)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginState = loginService.setEnabled(enabled)
    }

    func openLoginApprovalSettings() {
        loginService.openApprovalSettings()
    }

    func openLocalNetworkSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocalNetwork") else { return }
        NSWorkspace.shared.open(url)
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Eko-Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        Task {
            do {
                try await diagnostics.export(
                    to: url,
                    store: store,
                    identityFingerprint: identity.fingerprint,
                    appVersion: version,
                    includeNotificationContent: includeContentInDiagnostics
                )
            } catch {
                await MainActor.run { self.setFatalError(error) }
            }
            // docs/security-model.md: "Enabling content applies to one export, not future
            // exports." Nothing reset it, so it stayed on for the rest of the session and
            // silently applied to the next export too.
            await MainActor.run { self.includeContentInDiagnostics = false }
        }
    }

    func refreshDiagnostics() {
        Task {
            let events = await diagnostics.recentEvents()
            await MainActor.run { self.diagnosticsEvents = events }
        }
    }

    /// A `pool.read` that used to run synchronously on the main thread, once per
    /// committed event.
    func refreshGaps() async {
        let store = self.store
        let value = await Task.detached(priority: .utility) { (try? store.gaps()) ?? [] }.value
        gaps = value
    }

    func panelVisibilityChanged(_ visible: Bool) {
        relativeTimeTask?.cancel()
        relativeTimeTask = nil
        panelVisible = visible
        // The feed observation is a full `notification` scan plus a temp sort plus a
        // correlated per-row OTP subquery, re-executed by GRDB on every ingest
        // transaction. Leaving it running while the panel is hidden meant a backlog
        // replay burned that cost thousands of times over with nothing on screen to show
        // for it, each result assigning a fresh 400-element array to @Published and
        // re-triggering the status item.
        guard visible else {
            feedTask?.cancel()
            feedTask = nil
            return
        }
        restartFeedObservation()
        relativeTimeTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.now = Date()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func startObservations() {
        devicesTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await value in store.observeDevices() {
                    self.devices = value
                }
            } catch {
                self.setFatalError(error)
            }
        }
        preferencesTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await value in store.observeAppPreferences() {
                    self.appPreferences = value
                }
            } catch {
                self.setFatalError(error)
            }
        }
        restartFeedObservation()
        Task { await refreshGaps() }
    }

    private func scheduleFeedObservation() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.restartFeedObservation()
        }
    }

    private func restartFeedObservation() {
        feedTask?.cancel()
        // Nothing to observe for while the panel is hidden; panelVisibilityChanged(true)
        // restarts it. The initial value is `true` so the model behaves exactly as before
        // until the panel controller reports its first transition.
        guard panelVisible else {
            feedTask = nil
            return
        }
        let query = FeedQuery(
            search: searchText,
            deviceID: selectedDeviceID,
            codesOnly: codesOnly,
            limit: 400
        )
        feedTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await value in store.observeNotifications(query: query) {
                    self.notifications = value
                }
            } catch is CancellationError {
                return
            } catch {
                self.setFatalError(error)
            }
        }
    }

    private static var localHostName: String {
        let raw = Host.current().name ?? ProcessInfo.processInfo.hostName
        return raw.contains(".") ? raw : raw + ".local"
    }
}
