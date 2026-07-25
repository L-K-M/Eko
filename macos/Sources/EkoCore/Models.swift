import Foundation

public enum PairingState: String, Codable, Sendable {
    case pending
    case confirmed
    case revokedPending = "revoked_pending"
}

public enum EventKind: String, Codable, Sendable {
    case posted
    case updated
    case removed
    case captureGap = "capture_gap"
}

public enum GapConfidence: String, Codable, Sendable {
    case definitive
    case suspected
}

public struct StoredEvent: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(deviceID):\(generation):\(sequence)" }
    public let deviceID: String
    public let generation: String
    public let sequence: Int64
    public let kind: EventKind
    public let notificationKey: String?
    public let payloadJSON: Data
    public let contentHash: String?
    public let receivedAt: Date
    public let replayed: Bool
    public let payloadPruned: Bool

    public init(
        deviceID: String,
        generation: String,
        sequence: Int64,
        kind: EventKind,
        notificationKey: String?,
        payloadJSON: Data,
        contentHash: String?,
        receivedAt: Date,
        replayed: Bool,
        payloadPruned: Bool = false
    ) {
        self.deviceID = deviceID
        self.generation = generation
        self.sequence = sequence
        self.kind = kind
        self.notificationKey = notificationKey
        self.payloadJSON = payloadJSON
        self.contentHash = contentHash
        self.receivedAt = receivedAt
        self.replayed = replayed
        self.payloadPruned = payloadPruned
    }
}

public struct SessionDiagnostics: Equatable, Sendable {
    public let deviceID: String
    public let generation: String
    public let protocolVersion: Int
    public let connectionEpoch: Int64
    public let clockSkewMilliseconds: Int64

    public init(
        deviceID: String,
        generation: String,
        protocolVersion: Int,
        connectionEpoch: Int64,
        clockSkewMilliseconds: Int64
    ) {
        self.deviceID = deviceID
        self.generation = generation
        self.protocolVersion = protocolVersion
        self.connectionEpoch = connectionEpoch
        self.clockSkewMilliseconds = clockSkewMilliseconds
    }
}

public struct Device: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public var name: String
    public let pinnedCertificateDER: Data
    public var pairingState: PairingState
    public var currentGeneration: String?
    public var processedThroughSequence: Int64
    public var lastIPAddress: String?
    public var capabilities: [String]
    public var highestProtocolVersion: Int
    public var highestConnectionEpoch: Int64
    public var lastSeen: Date?

    public init(
        id: String,
        name: String,
        pinnedCertificateDER: Data,
        pairingState: PairingState,
        currentGeneration: String?,
        processedThroughSequence: Int64,
        lastIPAddress: String?,
        capabilities: [String],
        highestProtocolVersion: Int,
        highestConnectionEpoch: Int64,
        lastSeen: Date?
    ) {
        self.id = id
        self.name = name
        self.pinnedCertificateDER = pinnedCertificateDER
        self.pairingState = pairingState
        self.currentGeneration = currentGeneration
        self.processedThroughSequence = processedThroughSequence
        self.lastIPAddress = lastIPAddress
        self.capabilities = capabilities
        self.highestProtocolVersion = highestProtocolVersion
        self.highestConnectionEpoch = highestConnectionEpoch
        self.lastSeen = lastSeen
    }
}

public struct CurrentNotification: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(deviceID):\(generation):\(key)" }
    public let deviceID: String
    public let deviceName: String
    public let generation: String
    public let key: String
    public let appPackage: String
    public let appLabel: String
    public let title: String?
    public let body: String
    public let contentHash: String?
    public let lastStateSequence: Int64
    public let postedAt: Date?
    public let receivedAt: Date
    public let isActive: Bool
    public let isReplayed: Bool
    public let isGroupSummary: Bool
    public let isStarred: Bool
    public let otpCode: String?
    public let otpEventSequence: Int64?

    public init(
        deviceID: String,
        deviceName: String,
        generation: String,
        key: String,
        appPackage: String,
        appLabel: String,
        title: String?,
        body: String,
        contentHash: String?,
        lastStateSequence: Int64,
        postedAt: Date?,
        receivedAt: Date,
        isActive: Bool,
        isReplayed: Bool,
        isGroupSummary: Bool,
        isStarred: Bool,
        otpCode: String?,
        otpEventSequence: Int64?
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.generation = generation
        self.key = key
        self.appPackage = appPackage
        self.appLabel = appLabel
        self.title = title
        self.body = body
        self.contentHash = contentHash
        self.lastStateSequence = lastStateSequence
        self.postedAt = postedAt
        self.receivedAt = receivedAt
        self.isActive = isActive
        self.isReplayed = isReplayed
        self.isGroupSummary = isGroupSummary
        self.isStarred = isStarred
        self.otpCode = otpCode
        self.otpEventSequence = otpEventSequence
    }
}

public struct GapSpan: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(deviceID):\(generation):\(fromSequence):\(toSequence)" }
    public let deviceID: String
    public let generation: String
    public let fromSequence: Int64
    public let toSequence: Int64
    public let reason: String
    public let startTime: Date?
    public let endTime: Date?
    public let confidence: GapConfidence
}

public struct StoredOTP: Identifiable, Codable, Equatable, Sendable {
    public let id: Int64
    public let deviceID: String
    public let generation: String
    public let notificationKey: String
    public let eventSequence: Int64
    public let code: String
    public let method: String
    public let detectedAt: Date
    public let bannerEligible: Bool
    public let copiedAt: Date?
}

public struct IngestOutcome: Equatable, Sendable {
    public let deviceID: String
    public let generation: String
    public let sequence: Int64
    public let kind: EventKind
    public let notificationKey: String?
    public let appPackage: String?
    public let appLabel: String?
    public let title: String?
    public let body: String?
    public let otpCode: String?
    public let otpBannerEligible: Bool
    public let replayed: Bool
    public let dndSuppressed: Bool
    public let duplicate: Bool

    public init(
        deviceID: String,
        generation: String,
        sequence: Int64,
        kind: EventKind,
        notificationKey: String?,
        appPackage: String?,
        appLabel: String?,
        title: String?,
        body: String?,
        otpCode: String?,
        otpBannerEligible: Bool,
        replayed: Bool,
        dndSuppressed: Bool,
        duplicate: Bool
    ) {
        self.deviceID = deviceID
        self.generation = generation
        self.sequence = sequence
        self.kind = kind
        self.notificationKey = notificationKey
        self.appPackage = appPackage
        self.appLabel = appLabel
        self.title = title
        self.body = body
        self.otpCode = otpCode
        self.otpBannerEligible = otpBannerEligible
        self.replayed = replayed
        self.dndSuppressed = dndSuppressed
        self.duplicate = duplicate
    }
}

public enum BannerMode: String, Codable, CaseIterable, Sendable {
    case normal
    case silent
    case muted
}

public struct AppPreference: Identifiable, Codable, Equatable, Sendable {
    public var id: String { "\(deviceID):\(appPackage)" }
    public let deviceID: String
    public let deviceName: String
    public let appPackage: String
    public let appLabel: String
    public var bannerMode: BannerMode
    public var autoCopyOTP: Bool
    public var soundEnabled: Bool

    public init(
        deviceID: String,
        deviceName: String,
        appPackage: String,
        appLabel: String,
        bannerMode: BannerMode,
        autoCopyOTP: Bool,
        soundEnabled: Bool
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appPackage = appPackage
        self.appLabel = appLabel
        self.bannerMode = bannerMode
        self.autoCopyOTP = autoCopyOTP
        self.soundEnabled = soundEnabled
    }
}

public struct BacklogSummary: Equatable, Sendable {
    public let deviceID: String
    public let deviceName: String
    public let notificationCount: Int
    public let otpCount: Int

    public init(deviceID: String, deviceName: String, notificationCount: Int, otpCount: Int) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.notificationCount = notificationCount
        self.otpCount = otpCount
    }
}

public struct StoreDiagnostics: Codable, Equatable, Sendable {
    public let deviceCount: Int
    public let eventCount: Int
    public let activeNotificationCount: Int
    public let gapCount: Int
    public let otpCount: Int
    public let databaseBytes: Int64
}
