import Foundation
import OSLog

public enum DiagnosticLevel: String, Codable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let level: DiagnosticLevel
    public let category: String
    public let message: String

    public init(timestamp: Date, level: DiagnosticLevel, category: String, message: String) {
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

public struct DiagnosticsNotification: Codable, Equatable, Sendable {
    public let deviceID: String
    public let appPackage: String
    public let receivedAt: Date
    public let title: String?
    public let body: String?
    public let titleCharacterCount: Int?
    public let bodyCharacterCount: Int
}

public struct DiagnosticsDevice: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let certificateFingerprint: String
    public let pairingState: PairingState
    public let currentGeneration: String?
    public let processedThroughSequence: Int64
    public let lastAddressClass: String?
    public let capabilities: [String]
    public let highestProtocolVersion: Int
    public let highestConnectionEpoch: Int64
    public let lastSeen: Date?
}

public struct DiagnosticsEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let level: DiagnosticLevel
    public let category: String
    public let message: String
    public let messageCharacterCount: Int
    public let messageDigest: String
}

public struct DiagnosticsExport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let operatingSystem: String
    public let identityFingerprint: String
    public let store: StoreDiagnostics
    public let devices: [DiagnosticsDevice]
    public let events: [DiagnosticsEvent]
    public let notifications: [DiagnosticsNotification]
    public let notificationContentIncluded: Bool
}

public actor DiagnosticsRecorder {
    private let logger = Logger(subsystem: "com.eko.mac", category: "diagnostics")
    private let clock: any EkoClock
    private var events: [DiagnosticEvent] = []
    private let capacity: Int
    private let exportWriter = DiagnosticsExportWriter()

    public init(clock: any EkoClock = SystemEkoClock(), capacity: Int = 500) {
        self.clock = clock
        self.capacity = min(max(capacity, 100), 5_000)
    }

    public func record(_ level: DiagnosticLevel, category: String, message: String) {
        let category = Self.safeCategory(category)
        let sanitized = String(message.prefix(2_000))
        events.append(DiagnosticEvent(timestamp: clock.now(), level: level, category: category, message: sanitized))
        if events.count > capacity { events.removeFirst(events.count - capacity) }
        switch level {
        case .debug: logger.debug("[\(category, privacy: .public)] \(sanitized, privacy: .private)")
        case .info: logger.info("[\(category, privacy: .public)] \(sanitized, privacy: .private)")
        case .warning: logger.warning("[\(category, privacy: .public)] \(sanitized, privacy: .private)")
        case .error: logger.error("[\(category, privacy: .public)] \(sanitized, privacy: .private)")
        }
    }

    public func recentEvents() -> [DiagnosticEvent] {
        events
    }

    public func export(
        to url: URL,
        store: EkoStore,
        identityFingerprint: String,
        appVersion: String,
        includeNotificationContent: Bool
    ) async throws {
        let generatedAt = clock.now()
        let eventSnapshot = events
        try await exportWriter.write(
            to: url,
            store: store,
            identityFingerprint: identityFingerprint,
            appVersion: appVersion,
            includeNotificationContent: includeNotificationContent,
            generatedAt: generatedAt,
            events: eventSnapshot
        )
    }

    fileprivate static func writeExport(
        to url: URL,
        store: EkoStore,
        identityFingerprint: String,
        appVersion: String,
        includeNotificationContent: Bool,
        generatedAt: Date,
        events: [DiagnosticEvent]
    ) throws {
        let redactor = try DiagnosticsExportRedactor()
        let sourceDevices = try store.devices()
        var exportedDevices: [DiagnosticsDevice] = []
        var deviceAliases: [String: String] = [:]

        for device in sourceDevices {
            let deviceAlias = redactor.pseudonym(device.id, kind: "device")
            let deviceLabel = deviceAlias.replacingOccurrences(of: "device-", with: "phone-")
            let certificateFingerprint = EkoCrypto.fingerprint(of: device.pinnedCertificateDER)
            let certificateAlias = redactor.pseudonym(
                certificateFingerprint,
                kind: "certificate"
            )
            deviceAliases[device.id] = deviceAlias
            exportedDevices.append(DiagnosticsDevice(
                id: deviceAlias,
                name: deviceLabel,
                certificateFingerprint: certificateAlias,
                pairingState: device.pairingState,
                currentGeneration: device.currentGeneration.map {
                    redactor.pseudonym($0, kind: "generation")
                },
                processedThroughSequence: device.processedThroughSequence,
                lastAddressClass: Self.addressClass(device.lastIPAddress),
                capabilities: device.capabilities,
                highestProtocolVersion: device.highestProtocolVersion,
                highestConnectionEpoch: device.highestConnectionEpoch,
                lastSeen: device.lastSeen
            ))
        }

        let sourceNotifications = try store.notifications(query: FeedQuery(limit: 100))
        var exportedNotifications: [DiagnosticsNotification] = []
        for notification in sourceNotifications {
            let deviceAlias = deviceAliases[notification.deviceID]
                ?? redactor.pseudonym(notification.deviceID, kind: "device")
            let appAlias = redactor.pseudonym(notification.appPackage, kind: "app")
            exportedNotifications.append(DiagnosticsNotification(
                deviceID: deviceAlias,
                appPackage: appAlias,
                receivedAt: notification.receivedAt,
                title: includeNotificationContent
                    ? notification.title
                    : notification.title.map { _ in "<redacted>" },
                body: includeNotificationContent ? notification.body : "<redacted>",
                titleCharacterCount: notification.title?.count,
                bodyCharacterCount: notification.body.count
            ))
        }

        let redactedIdentity = redactor.pseudonym(
            identityFingerprint,
            kind: "identity"
        )
        let exportedEvents = events.map { event in
            DiagnosticsEvent(
                timestamp: event.timestamp,
                level: event.level,
                category: Self.safeCategory(event.category),
                message: "<redacted>",
                messageCharacterCount: event.message.count,
                messageDigest: redactor.pseudonym(event.message, kind: "event-message")
            )
        }
        let payload = DiagnosticsExport(
            schemaVersion: 1,
            generatedAt: generatedAt,
            appVersion: appVersion,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            identityFingerprint: redactedIdentity,
            store: try store.diagnostics(),
            devices: exportedDevices,
            events: exportedEvents,
            notifications: exportedNotifications,
            notificationContentIncluded: includeNotificationContent
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: url, options: [.atomic])
    }

    private static func safeCategory(_ category: String) -> String {
        switch category {
        case "backlog", "dismiss", "ingest", "listener", "notifications",
             "protocol", "retention", "session", "unpair":
            return category
        default:
            return "redacted"
        }
    }

    private static func addressClass(_ endpoint: String?) -> String? {
        guard let endpoint, !endpoint.isEmpty else { return nil }
        let host: String
        if endpoint.hasPrefix("["), let closingBracket = endpoint.firstIndex(of: "]") {
            host = String(endpoint[endpoint.index(after: endpoint.startIndex)..<closingBracket])
        } else if endpoint.filter({ $0 == ":" }).count > 1 {
            host = endpoint
        } else {
            host = String(endpoint.split(separator: ":", maxSplits: 1).first ?? "")
        }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else {
            if host == "::1" { return "ipv6-loopback" }
            if host.contains(":") { return "ipv6" }
            return "hostname"
        }
        switch (octets[0], octets[1]) {
        case (127, _): return "ipv4-loopback"
        case (10, _), (192, 168): return "ipv4-private"
        case (172, 16...31): return "ipv4-private"
        case (169, 254): return "ipv4-link-local"
        default: return "ipv4-public"
        }
    }
}

private struct DiagnosticsExportRedactor {
    private let salt: Data

    init() throws {
        salt = try EkoCrypto.randomBytes(count: 32)
    }

    func pseudonym(_ value: String, kind: String) -> String {
        var input = salt
        input.append(Data(kind.utf8))
        input.append(0)
        input.append(Data(value.utf8))
        let digest = EkoCrypto.sha256(input).hexLowercased
        return "\(kind)-\(digest.prefix(24))"
    }
}

private actor DiagnosticsExportWriter {
    func write(
        to url: URL,
        store: EkoStore,
        identityFingerprint: String,
        appVersion: String,
        includeNotificationContent: Bool,
        generatedAt: Date,
        events: [DiagnosticEvent]
    ) throws {
        try DiagnosticsRecorder.writeExport(
            to: url,
            store: store,
            identityFingerprint: identityFingerprint,
            appVersion: appVersion,
            includeNotificationContent: includeNotificationContent,
            generatedAt: generatedAt,
            events: events
        )
    }
}
