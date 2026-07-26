import EkoCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TabView {
            GeneralSettingsView(model: model)
                .tabItem { Label("settings.general", systemImage: "gear") }
            DevicesSettingsView(model: model)
                .tabItem { Label("settings.devices", systemImage: "iphone.gen3") }
            NotificationSettingsView(model: model)
                .tabItem { Label("settings.notifications", systemImage: "bell") }
            DiagnosticsSettingsView(model: model)
                .tabItem { Label("settings.diagnostics", systemImage: "waveform.path.ecg") }
        }
        .padding(18)
        .frame(minWidth: 640, minHeight: 480)
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("settings.startup") {
                Toggle(
                    String(localized: "settings.launch_at_login", defaultValue: "Launch Eko at login"),
                    isOn: Binding(
                        get: { model.launchAtLoginState == .enabled },
                        set: model.setLaunchAtLogin
                    )
                )
                .accessibilityHint(String(localized: "settings.launch_at_login.hint", defaultValue: "Starts the menu bar app after you sign in"))
                if model.launchAtLoginState == .requiresApproval {
                    Button(String(localized: "settings.login_approval", defaultValue: "Open Login Items Settings")) {
                        model.openLoginApprovalSettings()
                    }
                } else if model.launchAtLoginState == .outsideApplications {
                    Label("settings.move_to_applications", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
            Section("settings.clipboard") {
                Toggle("settings.clipboard_clear", isOn: $model.clipboardAutoClear)
                Text("settings.clipboard_detail")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("settings.history") {
                Stepper(value: $model.retentionDays, in: 1...90) {
                    LabeledContent(String(localized: "settings.retention_days", defaultValue: "Keep history"), value: "\(model.retentionDays) d")
                }
                Stepper(value: $model.retentionCount, in: 100...50_000, step: 100) {
                    LabeledContent(String(localized: "settings.retention_count", defaultValue: "Per phone"), value: model.retentionCount.formatted())
                }
            }
            Section("settings.network") {
                LabeledContent(String(localized: "settings.listener_port", defaultValue: "Listener port"), value: model.boundPort.map(String.init) ?? "—")
                Stepper(value: $model.configuredPort, in: 1_024...65_535) {
                    LabeledContent(String(localized: "settings.preferred_port", defaultValue: "Preferred port"), value: String(model.configuredPort))
                }
                Text("settings.port_restart")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent(String(localized: "settings.identity", defaultValue: "Mac identity"), value: String(model.identity.fingerprint.prefix(16)) + "…")
            }
        }
        .formStyle(.grouped)
    }
}

private struct DevicesSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var devicePendingForget: Device?
    @State private var showForgetDialog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("settings.devices")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    model.beginPairing()
                } label: {
                    Label("pairing.add_phone", systemImage: "plus")
                }
            }
            if model.devices.isEmpty {
                ContentUnavailableView("settings.no_devices", systemImage: "iphone.slash")
            } else {
                List(model.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone.gen3")
                            .font(.title2)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.headline)
                            Text(device.id)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if device.pairingState == .revokedPending {
                                Text(String(localized: "device.unpair_pending", defaultValue: "Unpair pending — notification mirroring is off. Re-pair via Add phone."))
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else if let seen = device.lastSeen {
                                Text(seen, style: .relative)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if device.pairingState == .revokedPending {
                            Text(String(localized: "device.revoked", defaultValue: "Revoked"))
                                .font(.caption.weight(.medium))
                        } else {
                            Text(connectionLabel(model.connectionStates[device.id] ?? .disconnected))
                                .font(.caption.weight(.medium))
                        }
                        Button(String(localized: "action.unpair", defaultValue: "Unpair"), role: .destructive) {
                            model.requestUnpair(device)
                        }
                        .accessibilityLabel(String(localized: "action.unpair", defaultValue: "Unpair") + " " + device.name)
                        if device.pairingState == .revokedPending {
                            Button(String(localized: "action.forget", defaultValue: "Forget…"), role: .destructive) {
                                devicePendingForget = device
                                showForgetDialog = true
                            }
                            .accessibilityLabel(String(localized: "action.forget", defaultValue: "Forget") + " " + device.name)
                        }
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .confirmationDialog(
            String(localized: "device.forget.title", defaultValue: "Forget without notifying?"),
            isPresented: $showForgetDialog,
            titleVisibility: .visible,
            presenting: devicePendingForget
        ) { device in
            Button(String(localized: "action.forget", defaultValue: "Forget"), role: .destructive) {
                model.forgetWithoutNotifying(device)
            }
            Button(String(localized: "action.cancel", defaultValue: "Cancel"), role: .cancel) {}
        } message: { device in
            Text(String.localizedStringWithFormat(
                String(localized: "device.forget.message", defaultValue: "%@ will be forgotten immediately without notifying the phone. Pairing history and the pending unpair receipt are deleted; the phone must pair again from scratch."),
                device.name
            ))
        }
    }

    private func connectionLabel(_ state: DeviceConnectionState) -> String {
        switch state {
        case .online: return String(localized: "connection.online", defaultValue: "Connected")
        case .synchronizing: return String(localized: "connection.syncing", defaultValue: "Syncing")
        case .connecting: return String(localized: "connection.connecting", defaultValue: "Connecting")
        case .disconnected: return String(localized: "connection.disconnected", defaultValue: "Disconnected")
        case .failed: return String(localized: "connection.failed", defaultValue: "Connection failed")
        }
    }
}

private struct NotificationSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("settings.notifications")
                .font(.title2.weight(.semibold))
            Text("settings.notifications.detail")
                .foregroundStyle(.secondary)
            Toggle("settings.pause_banners", isOn: $model.bannersPaused)
                .accessibilityHint(String(localized: "settings.pause_banners.hint", defaultValue: "Notifications continue to arrive in the panel"))
            if model.appPreferences.isEmpty {
                ContentUnavailableView("settings.no_apps", systemImage: "app.dashed")
            } else {
                List(model.appPreferences) { preference in
                    PreferenceRow(preference: preference, onChange: model.updatePreference)
                }
            }
            Text("settings.banner_guidance")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PreferenceRow: View {
    @State private var preference: AppPreference
    let onChange: (AppPreference) -> Void

    init(preference: AppPreference, onChange: @escaping (AppPreference) -> Void) {
        _preference = State(initialValue: preference)
        self.onChange = onChange
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "app")
                .accessibilityHidden(true)
            VStack(alignment: .leading) {
                Text(preference.appLabel).font(.headline)
                Text("\(preference.deviceName) · \(preference.appPackage)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("settings.delivery", selection: $preference.bannerMode) {
                Text("settings.delivery.normal").tag(BannerMode.normal)
                Text("settings.delivery.silent").tag(BannerMode.silent)
                Text("settings.delivery.muted").tag(BannerMode.muted)
            }
            .frame(width: 120)
            Toggle("settings.sound", isOn: $preference.soundEnabled)
                .toggleStyle(.checkbox)
            Toggle("settings.auto_copy", isOn: $preference.autoCopyOTP)
                .toggleStyle(.checkbox)
        }
        .onChange(of: preference) { _, value in onChange(value) }
        .accessibilityElement(children: .contain)
    }
}

private struct DiagnosticsSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("settings.diagnostics")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button(String(localized: "diagnostics.refresh", defaultValue: "Refresh")) { model.refreshDiagnostics() }
                Button(String(localized: "diagnostics.export", defaultValue: "Export…")) { model.exportDiagnostics() }
                    .buttonStyle(.borderedProminent)
            }
            HStack(spacing: 10) {
                StateCard(title: String(localized: "diagnostics.listener", defaultValue: "TLS listener"), value: listenerLabel(model.listenerState))
                StateCard(title: String(localized: "diagnostics.bonjour", defaultValue: "Bonjour"), value: bonjourLabel(model.bonjourState))
                StateCard(title: String(localized: "diagnostics.bluetooth", defaultValue: "Bluetooth"), value: bluetoothLabel(model.bluetoothState))
            }
            Toggle("diagnostics.include_content", isOn: $model.includeContentInDiagnostics)
            Text("diagnostics.content_warning")
                .font(.caption)
                .foregroundStyle(.secondary)
            List(model.diagnosticsEvents, id: \.timestamp) { event in
                HStack(alignment: .firstTextBaseline) {
                    Text(event.timestamp, style: .time)
                        .font(.caption.monospacedDigit())
                    Text(event.category)
                        .font(.caption.weight(.semibold))
                    Text(event.message)
                        .font(.caption)
                        .textSelection(.enabled)
                    Spacer()
                }
            }
        }
        .onAppear { model.refreshDiagnostics() }
    }

    // Raw String(describing:) enum dumps like "ready(port: 48808, usedFallback:
    // false)" are neither readable nor localizable; failure details remain
    // visible in the event list below.
    private func listenerLabel(_ state: TLSListenerState) -> String {
        switch state {
        case .stopped: return String(localized: "diagnostics.state.stopped", defaultValue: "Stopped")
        case .starting: return String(localized: "diagnostics.state.starting", defaultValue: "Starting")
        case .ready(let port, let usedFallback):
            let base = String.localizedStringWithFormat(
                String(localized: "diagnostics.listener.ready", defaultValue: "Listening on port %d"),
                Int(port)
            )
            return usedFallback
                ? base + " " + String(localized: "diagnostics.listener.fallback", defaultValue: "(fallback port)")
                : base
        case .waiting: return String(localized: "diagnostics.state.waiting", defaultValue: "Waiting for network")
        case .failed: return String(localized: "diagnostics.state.failed", defaultValue: "Failed")
        }
    }

    private func bonjourLabel(_ state: BonjourPublicationState) -> String {
        switch state {
        case .stopped: return String(localized: "diagnostics.state.stopped", defaultValue: "Stopped")
        case .publishing: return String(localized: "diagnostics.bonjour.publishing", defaultValue: "Publishing")
        case .published: return String(localized: "diagnostics.bonjour.published", defaultValue: "Published")
        case .policyDenied: return String(localized: "diagnostics.bonjour.policy_denied", defaultValue: "Local Network access denied")
        case .failed: return String(localized: "diagnostics.state.failed", defaultValue: "Failed")
        }
    }

    private func bluetoothLabel(_ state: BLEAdvertisingState) -> String {
        switch state {
        case .stopped: return String(localized: "diagnostics.state.stopped", defaultValue: "Stopped")
        case .starting: return String(localized: "diagnostics.state.starting", defaultValue: "Starting")
        case .advertising: return String(localized: "diagnostics.bluetooth.advertising", defaultValue: "Advertising")
        case .poweredOff: return String(localized: "diagnostics.bluetooth.powered_off", defaultValue: "Bluetooth is off")
        case .unauthorized: return String(localized: "diagnostics.bluetooth.unauthorized", defaultValue: "Not authorized")
        case .unsupported: return String(localized: "diagnostics.bluetooth.unsupported", defaultValue: "Not supported")
        case .failed: return String(localized: "diagnostics.state.failed", defaultValue: "Failed")
        }
    }
}

private struct StateCard: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}
