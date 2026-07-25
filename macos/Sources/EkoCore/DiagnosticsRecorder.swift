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
}

public struct DiagnosticsExport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let appVersion: String
    public let operatingSystem: String
    public let identityFingerprint: String
    public let store: StoreDiagnostics
    public let devices: [Device]
    public let events: [DiagnosticEvent]
    public let notifications: [DiagnosticsNotification]
    public let notificationContentIncluded: Bool
}

public actor DiagnosticsRecorder {
    private let logger = Logger(subsystem: "com.eko.mac", category: "diagnostics")
    private let clock: any EkoClock
    private var events: [DiagnosticEvent] = []
    private let capacity: Int

    public init(clock: any EkoClock = SystemEkoClock(), capacity: Int = 500) {
        self.clock = clock
        self.capacity = min(max(capacity, 100), 5_000)
    }

    public func record(_ level: DiagnosticLevel, category: String, message: String) {
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
    ) throws {
        let notifications = try store.notifications(query: FeedQuery(limit: 100)).map {
            DiagnosticsNotification(
                deviceID: $0.deviceID,
                appPackage: $0.appPackage,
                receivedAt: $0.receivedAt,
                title: includeNotificationContent ? $0.title : nil,
                body: includeNotificationContent ? $0.body : nil
            )
        }
        let payload = DiagnosticsExport(
            generatedAt: clock.now(),
            appVersion: appVersion,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            identityFingerprint: identityFingerprint,
            store: try store.diagnostics(),
            devices: try store.devices(),
            events: events,
            notifications: notifications,
            notificationContentIncluded: includeNotificationContent
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(payload).write(to: url, options: [.atomic])
    }
}
