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
    /// Seconds after which a code copied on the user's behalf is cleared from
    /// the clipboard, or nil to leave it. Mirrors the panel's copy behavior so
    /// the auto-clear preference applies to every copy path.
    func clipboardClearAfter() -> TimeInterval?
}

public extension NotificationDeliveryPolicy {
    func clipboardClearAfter() -> TimeInterval? { 120 }
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
        // .sound must be requested or per-app sound preferences can never
        // play: UNUserNotificationCenter ignores content.sound without it.
        try await center.requestAuthorization(options: [.alert, .badge, .sound, .provisional])
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
    private static let bankingStylePattern = try! NSRegularExpression(
        pattern: #"(?:bank|payment|transaction|zahlung|betrag|überweisung|ueberweisung|uberweisung|finance|finanz|card|karte|mtan|smstan|phototan|pushtan|chiptan|\btan\b|\b(?:CHF|EUR|USD)\b)"#,
        options: [.caseInsensitive]
    )

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
           !Self.isBankingStyle(
               title: outcome.title,
               body: outcome.body,
               appLabel: outcome.appLabel,
               appPackage: outcome.appPackage
           ) {
            await clipboard.copy(code, clearAfter: deliveryPolicy.clipboardClearAfter())
            try? store.markOTPCopied(deviceID: outcome.deviceID, code: code)
        }
        // For code-bearing notifications the store computes cross-key/time
        // dedupe (otpBannerEligible); honoring it only for .updated events let
        // every re-sent code on a fresh notification key banner again
        // (otp-corpus en-024). Codeless posted notifications banner as before.
        let bannerEligible = outcome.otpCode == nil
            ? outcome.kind == .posted
            : (outcome.kind == .posted || outcome.kind == .updated) && outcome.otpBannerEligible
        guard !outcome.dndSuppressed,
              deliveryPolicy.allowsBanner(deviceID: outcome.deviceID),
              (preference?.bannerMode ?? .normal) == .normal,
              bannerEligible else { return }
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
        // The reconnect summary is a banner like any other; honor Pause banners.
        guard deliveryPolicy.allowsBanner(deviceID: summary.deviceID) else { return }
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
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Without this, notifications are suppressed whenever Eko is the
        // active app — which it frequently is exactly when codes arrive,
        // since opening the panel or Settings activates the app.
        //
        // Re-check the banner gate at delivery time: a notification scheduled
        // just before the user paused banners is still in the system queue,
        // and presenting it would contradict the setting. It stays in the
        // notification list either way.
        if let deviceID = notification.request.content.userInfo["device_id"] as? String,
           !deliveryPolicy.allowsBanner(deviceID: deviceID) {
            completionHandler([.list])
            return
        }
        completionHandler([.banner, .list, .sound])
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
                await clipboard.copy(code, clearAfter: deliveryPolicy.clipboardClearAfter())
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

    static func isBankingStyle(
        title: String?,
        body: String?,
        appLabel: String?,
        appPackage: String?
    ) -> Bool {
        [title, body, appLabel, appPackage].compactMap { $0 }.contains { text in
            let normalized = text.precomposedStringWithCanonicalMapping
            bankingStylePattern.firstMatch(
                in: normalized,
                range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
            ) != nil
        }
    }
}
