import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import EkoCore
import Foundation
import SwiftUI

struct PanelRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var pairingBroker: PairingApprovalBroker
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(model: model, openSettings: openSettings)
            Divider().opacity(0.6)
            if let error = model.fatalError {
                ErrorStrip(message: error)
            }
            Group {
                switch model.route {
                case .feed:
                    FeedView(model: model)
                case .pairing:
                    PairingView(model: model, broker: pairingBroker)
                }
            }
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 460, idealHeight: 620)
        .background(.ultraThinMaterial)
    }
}

private struct PanelHeader: View {
    @ObservedObject var model: AppModel
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image("BrandMark")
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text("app.name")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.devices) { device in
                        DeviceChip(
                            device: device,
                            state: model.connectionStates[device.id] ?? .disconnected,
                            selected: model.selectedDeviceID == device.id
                        ) {
                            model.selectedDeviceID = model.selectedDeviceID == device.id ? nil : device.id
                            model.route = .feed
                        }
                    }
                }
            }
            Spacer(minLength: 4)
            Button {
                model.beginPairing()
            } label: {
                Image(systemName: "plus")
            }
            .help(String(localized: "pairing.add_phone", defaultValue: "Add phone"))
            .accessibilityLabel(String(localized: "pairing.add_phone", defaultValue: "Add phone"))
            Button(action: openSettings) {
                Image(systemName: "gearshape")
            }
            .help(String(localized: "settings.open", defaultValue: "Open settings"))
            .accessibilityLabel(String(localized: "settings.open", defaultValue: "Open settings"))
            Button {
                model.panelPinned.toggle()
            } label: {
                Image(systemName: model.panelPinned ? "pin.fill" : "pin")
            }
            .help(String(localized: "panel.pin", defaultValue: "Keep panel open"))
            .accessibilityLabel(String(localized: "panel.pin", defaultValue: "Keep panel open"))
            .accessibilityValue(model.panelPinned ? String(localized: "state.on", defaultValue: "On") : String(localized: "state.off", defaultValue: "Off"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
    }
}

private struct DeviceChip: View {
    let device: Device
    let state: DeviceConnectionState
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: stateSymbol)
                    .font(.system(size: 8, weight: .bold))
                Text(device.name)
                    .lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(selected ? Color.accentColor.opacity(0.7) : Color.clear))
        }
        .buttonStyle(.plain)
        .help("\(device.name): \(stateLabel)")
        .accessibilityLabel("\(device.name), \(stateLabel)")
    }

    private var stateSymbol: String {
        switch state {
        case .online: return "circle.fill"
        case .synchronizing, .connecting: return "circle.dotted"
        case .disconnected: return "circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var stateLabel: String {
        switch state {
        case .online: return String(localized: "connection.online", defaultValue: "Connected")
        case .synchronizing: return String(localized: "connection.syncing", defaultValue: "Syncing")
        case .connecting: return String(localized: "connection.connecting", defaultValue: "Connecting")
        case .disconnected: return String(localized: "connection.disconnected", defaultValue: "Disconnected")
        case .failed: return String(localized: "connection.failed", defaultValue: "Connection failed")
        }
    }
}

private struct ErrorStrip: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.red.opacity(0.88))
            .accessibilityLabel(String(localized: "error.label", defaultValue: "Error") + ": " + message)
    }
}

struct FeedView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            searchAndFilters
            degradedState
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.gaps.prefix(3)) { gap in
                            GapRow(gap: gap, deviceName: model.devices.first(where: { $0.id == gap.deviceID })?.name)
                        }
                        notificationRows
                        if model.notifications.isEmpty {
                            EmptyFeedView(hasDevices: !model.devices.isEmpty)
                                .padding(.top, 56)
                        }
                    }
                    .padding(10)
                }
                .onChange(of: model.focusedNotificationID) { _, value in
                    if let value { withAnimation { proxy.scrollTo(value, anchor: .center) } }
                }
            }
        }
    }

    private var searchAndFilters: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(String(localized: "feed.search", defaultValue: "Search notifications"), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .accessibilityLabel(String(localized: "feed.search", defaultValue: "Search notifications"))
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "feed.clear_search", defaultValue: "Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 6) {
                FilterButton(title: String(localized: "filter.all", defaultValue: "All"), selected: !model.codesOnly) {
                    model.codesOnly = false
                }
                FilterButton(title: String(localized: "filter.codes", defaultValue: "Codes"), selected: model.codesOnly) {
                    model.codesOnly = true
                }
                Spacer()
                Button {
                    model.groupByDevice.toggle()
                } label: {
                    Image(systemName: model.groupByDevice ? "rectangle.3.group.fill" : "rectangle.3.group")
                }
                .buttonStyle(.plain)
                .help(String(localized: "feed.group_device", defaultValue: "Group by phone"))
                .accessibilityLabel(String(localized: "feed.group_device", defaultValue: "Group by phone"))
                .accessibilityValue(model.groupByDevice ? String(localized: "state.on", defaultValue: "On") : String(localized: "state.off", defaultValue: "Off"))
                Text("\(model.notifications.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String.localizedStringWithFormat(String(localized: "feed.count", defaultValue: "%d notifications"), model.notifications.count))
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder private var notificationRows: some View {
        if model.groupByDevice {
            ForEach(model.devices.filter { device in
                model.notifications.contains(where: { $0.deviceID == device.id })
            }) { device in
                HStack {
                    Image(systemName: "iphone")
                    Text(device.name).font(.caption.weight(.semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)
                ForEach(model.notifications.filter { $0.deviceID == device.id }) { notification in
                    NotificationRow(model: model, notification: notification)
                        .id(notification.id)
                }
            }
        } else {
            ForEach(model.notifications) { notification in
                NotificationRow(model: model, notification: notification)
                    .id(notification.id)
            }
        }
    }

    @ViewBuilder private var degradedState: some View {
        if model.networkPathState == .localNetworkDenied || model.bonjourState == .policyDenied {
            HStack {
                Label(
                    String(localized: "degraded.local_network", defaultValue: "Local Network access is off. Discovery is disabled; direct connections still work."),
                    systemImage: "network.slash"
                )
                Spacer(minLength: 8)
                Button(String(localized: "degraded.open_settings", defaultValue: "Open Settings")) {
                    model.openLocalNetworkSettings()
                }
                .controlSize(.small)
            }
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08))
        }
    }
}

private struct FilterButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct NotificationRow: View {
    @ObservedObject var model: AppModel
    let notification: CurrentNotification
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(notification.appLabel)
                    .font(.caption.weight(.semibold))
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(notification.deviceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if notification.isReplayed {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .help(String(localized: "feed.replayed", defaultValue: "Received from backlog"))
                        .accessibilityLabel(String(localized: "feed.replayed", defaultValue: "Received from backlog"))
                }
                if !notification.isActive {
                    Text("feed.dismissed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(relativeDate(notification.receivedAt))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            if let code = notification.otpCode {
                HStack(alignment: .firstTextBaseline) {
                    Text(code)
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button(String(localized: "action.copy_code", defaultValue: "Copy code")) {
                        model.copyCode(code, deviceID: notification.deviceID)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "action.copy_code", defaultValue: "Copy code") + " " + code)
                }
            }
            if let title = notification.title, !title.isEmpty {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
            }
            Text(notification.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(notification.otpCode == nil ? 3 : 4)
                .textSelection(.enabled)

            if hovering || notification.otpCode != nil {
                HStack(spacing: 12) {
                    Button(String(localized: "action.copy_text", defaultValue: "Copy text")) {
                        model.copyText(notification.body)
                    }
                    if notification.isActive {
                        Button(String(localized: "action.dismiss", defaultValue: "Dismiss on phone")) {
                            model.dismiss(notification)
                        }
                    }
                    Button {
                        model.toggleStar(notification)
                    } label: {
                        Label(
                            notification.isStarred
                                ? String(localized: "action.unstar", defaultValue: "Unstar")
                                : String(localized: "action.star", defaultValue: "Keep"),
                            systemImage: notification.isStarred ? "star.fill" : "star"
                        )
                    }
                    Spacer()
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(notification.otpCode == nil ? Color(nsColor: .controlBackgroundColor).opacity(0.72) : Color.accentColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(notification.otpCode == nil ? Color.primary.opacity(0.06) : Color.accentColor.opacity(0.32))
        )
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        [notification.appLabel, notification.deviceName, notification.title, notification.body, notification.otpCode]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: model.now)
    }
}

private struct GapRow: View {
    let gap: GapSpan
    let deviceName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: gap.confidence == .definitive ? "exclamationmark.triangle.fill" : "questionmark.diamond.fill")
                .foregroundStyle(gap.confidence == .definitive ? .orange : .yellow)
            VStack(alignment: .leading, spacing: 2) {
                // A ternary of string literals types as String, not
                // LocalizedStringKey, so the keys must be resolved explicitly.
                Text(gap.confidence == .definitive
                    ? String(localized: "gap.definitive", defaultValue: "History unavailable")
                    : String(localized: "gap.suspected", defaultValue: "Phone may have missed notifications"))
                    .font(.caption.weight(.semibold))
                Text("\(deviceName ?? String(gap.deviceID.prefix(8))) · \(gap.reason)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(9)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyFeedView: View {
    let hasDevices: Bool

    var body: some View {
        ContentUnavailableView {
            Label(
                hasDevices ? String(localized: "feed.empty", defaultValue: "No notifications") : String(localized: "feed.no_devices", defaultValue: "Pair your first phone"),
                systemImage: hasDevices ? "bell.slash" : "iphone.gen3.radiowaves.left.and.right"
            )
        } description: {
            // A ternary of string literals types as String, not
            // LocalizedStringKey, so the keys must be resolved explicitly.
            Text(hasDevices
                ? String(localized: "feed.empty.detail", defaultValue: "New notifications from your phones appear here.")
                : String(localized: "feed.no_devices.detail", defaultValue: "Choose Add phone above and scan the QR code."))
        }
    }
}

struct PairingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var broker: PairingApprovalBroker

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                HStack {
                    Button {
                        model.endPairing()
                    } label: {
                        Label(String(localized: "action.back", defaultValue: "Back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("pairing.title")
                        .font(.headline)
                    Spacer()
                    Color.clear.frame(width: 44, height: 1)
                }

                if let pending = broker.pending {
                    PairingConfirmationView(pending: pending) { broker.resolve($0) }
                } else if let display = model.pairingDisplay {
                    QRCodeView(payload: display.qrPayload)
                        .frame(width: 220, height: 220)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityLabel(String(localized: "pairing.qr.accessibility", defaultValue: "Pairing QR code"))
                    Text("pairing.scan")
                        .font(.title3.weight(.semibold))
                    Text("pairing.scan.detail")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(String(localized: "pairing.address", defaultValue: "Address"), value: "\(display.host):\(display.port)")
                        LabeledContent(String(localized: "pairing.fingerprint", defaultValue: "Fingerprint"), value: String(display.fingerprint.prefix(16)) + "…")
                        LabeledContent(String(localized: "pairing.expires", defaultValue: "Expires")) {
                            Text(display.expiresAt, style: .relative)
                        }
                    }
                    .font(.caption.monospaced())
                    .padding(12)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
            }
            .padding(18)
        }
    }
}

private struct PairingConfirmationView: View {
    let pending: PendingPairing
    let resolve: (Bool) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 42))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(pending.deviceName)
                .font(.title2.weight(.semibold))
            Text("pairing.compare")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(pending.verificationCode)
                .font(.system(size: 34, weight: .bold, design: .monospaced))
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(String(localized: "pairing.verification_code", defaultValue: "Verification code") + " " + pending.verificationCode)
            Text(String(pending.certificateFingerprint.prefix(16)) + "…")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(String(localized: "action.reject", defaultValue: "Reject")) { resolve(false) }
                    .keyboardShortcut(.cancelAction)
                Button(String(localized: "action.confirm", defaultValue: "Confirm")) { resolve(true) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.vertical, 24)
    }
}

private struct QRCodeView: View {
    let payload: String

    var body: some View {
        if let image = makeImage() {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
        } else {
            Image(systemName: "qrcode")
                .resizable()
        }
    }

    private func makeImage() -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
