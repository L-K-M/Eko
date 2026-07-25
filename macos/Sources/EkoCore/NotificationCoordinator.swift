import Foundation
import UserNotifications

public struct NotificationStrings: Sendable {
    public let copyCodeAction: String
    public let backlogTitle: @Sendable (String) -> String
    public let backlogBody: @Sendable (Int, Int) -> String

    public init(
        copyCodeAction: String,
        backlogTitle: @escaping @Sendable (String) -> String,
        backlogBody: @escaping @Sendable (Int, Int) -> String
    ) {
        self.copyCodeAction = copyCodeAction
        self.backlogTitle = backlogTitle
        self.backlogBody = backlogBody
    }
}

public protocol UserNotificationScheduling: Sendable {
    func requestProvisionalAuthorization() async throws -> Bool
    func install(categories: Set<UNNotificationCategory>)
    func add(_ request: UNNotificationRequest) async throws
    func removeDelivered(identifiers: [String])
}

public protocol NotificationDeliveryPolicy: Sendable {
    func allowsBanner(deviceID: String) -> Bool
}

public struct AllowAllNotificationDeliveryPolicy: NotificationDeliveryPolicy {
    public init() {}
    public func allowsBanner(deviceID: String) -> Bool { true }
}

public final class SystemUserNotificationScheduler: UserNotificationScheduling, @unchecked Sendable {
    public let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestProvisionalAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .provisional])
    }

    public func install(categories: Set<UNNotificationCategory>) {
        center.setNotificationCategories(categories)
    }

    public func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    public func removeDelivered(identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

public final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let copyActionIdentifier = "EKO_COPY_CODE"
    public static let otpCategoryIdentifier = "EKO_OTP"

    private let scheduler: any UserNotificationScheduling
    private let systemCenter: UNUserNotificationCenter?
    private let store: EkoStore
    private let clipboard: ClipboardController
    private let strings: NotificationStrings
    private let deliveryPolicy: any NotificationDeliveryPolicy
    private let openPanel: @Sendable (String, String) async -> Void

    public init(
        scheduler: any UserNotificationScheduling = SystemUserNotificationScheduler(),
        store: EkoStore,
        clipboard: ClipboardController,
        strings: NotificationStrings,
        deliveryPolicy: any NotificationDeliveryPolicy = AllowAllNotificationDeliveryPolicy(),
        openPanel: @escaping @Sendable (String, String) async -> Void
    ) {
        self.scheduler = scheduler
        self.systemCenter = (scheduler as? SystemUserNotificationScheduler)?.center
        self.store = store
        self.clipboard = clipboard
        self.strings = strings
        self.deliveryPolicy = deliveryPolicy
        self.openPanel = openPanel
        super.init()
    }

    public func configure() async throws {
        let action = UNNotificationAction(
            identifier: Self.copyActionIdentifier,
            title: strings.copyCodeAction,
            options: [.authenticationRequired]
        )
        let category = UNNotificationCategory(
            identifier: Self.otpCategoryIdentifier,
            actions: [action],
            intentIdentifiers: [],
            options: []
        )
        scheduler.install(categories: [category])
        systemCenter?.delegate = self
        _ = try await scheduler.requestProvisionalAuthorization()
    }

    public func handleCommittedEvent(_ outcome: IngestOutcome, deviceName: String) async {
        guard !outcome.duplicate, !outcome.replayed, let key = outcome.notificationKey else { return }
        let preference = outcome.appPackage.flatMap { try? store.appPreference(deviceID: outcome.deviceID, appPackage: $0) }
        if let code = outcome.otpCode,
           preference?.autoCopyOTP == true,
           !Self.isBankingStyle(outcome.body ?? "") {
            await clipboard.copy(code)
            try? store.markOTPCopied(deviceID: outcome.deviceID, code: code)
        }
        guard !outcome.dndSuppressed,
              deliveryPolicy.allowsBanner(deviceID: outcome.deviceID),
              (preference?.bannerMode ?? .normal) == .normal,
              (outcome.kind == .posted || outcome.otpBannerEligible) else { return }
        let content = UNMutableNotificationContent()
        let app = outcome.appLabel ?? deviceName
        content.title = "\(app) · \(deviceName)"
        content.body = outcome.body ?? outcome.title ?? ""
        content.sound = preference?.soundEnabled == true ? .default : nil
        if outcome.otpCode != nil {
            content.categoryIdentifier = Self.otpCategoryIdentifier
        }
        content.userInfo = [
            "device_id": outcome.deviceID,
            "generation": outcome.generation,
            "notification_key": key,
        ]
        do {
            try await scheduler.add(UNNotificationRequest(
                identifier: Self.identifier(deviceID: outcome.deviceID, key: key),
                content: content,
                trigger: nil
            ))
        } catch {
            return
        }
    }

    public func postBacklogSummary(_ summary: BacklogSummary) async {
        let content = UNMutableNotificationContent()
        content.title = strings.backlogTitle(summary.deviceName)
        content.body = strings.backlogBody(summary.notificationCount, summary.otpCount)
        content.sound = nil
        do {
            try await scheduler.add(UNNotificationRequest(
                identifier: "eko.backlog.\(summary.deviceID).\(UUID().uuidString)",
                content: content,
                trigger: nil
            ))
        } catch {
            return
        }
    }

    public func removeDelivered(deviceID: String, key: String) {
        scheduler.removeDelivered(identifiers: [Self.identifier(deviceID: deviceID, key: key)])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        guard let deviceID = info["device_id"] as? String,
              let key = info["notification_key"] as? String else {
            completionHandler()
            return
        }
        let generation = info["generation"] as? String
        Task {
            if response.actionIdentifier == Self.copyActionIdentifier,
               let code = try? store.currentOTP(deviceID: deviceID, generation: generation, notificationKey: key) {
                await clipboard.copy(code)
                try? store.markOTPCopied(deviceID: deviceID, code: code)
            } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                await openPanel(deviceID, key)
            }
            completionHandler()
        }
    }

    private static func identifier(deviceID: String, key: String) -> String {
        "eko.notification." + EkoCrypto.sha256(Data("\(deviceID)\u{0}\(key)".utf8)).hexLowercased
    }

    static func isBankingStyle(_ text: String) -> Bool {
        text.range(
            of: #"\b(?:m?TAN|bank|payment|transaction|zahlung|betrag|überweisung|CHF|EUR|USD)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
