import Foundation

public enum ProtocolMode: String, Codable, Sendable {
    case normal
    case pair
    case unpair
}

public enum PairRole: String, Codable, Sendable {
    case phone
    case mac
}

public enum PairMethod: String, Codable, Sendable {
    case compare
    case qr
}

public enum PairResultKind: String, Codable, Sendable {
    case accept
    case reject
    case ready
    case confirmed
}

public enum PairRejectReason: String, Codable, Sendable {
    case userRejected = "user_rejected"
    case qrRejected = "qr_rejected"
}

public enum UnpairReason: String, Codable, Sendable {
    case userRequest = "user_request"
    case identityReplaced = "identity_replaced"
}

public enum UnpairStatus: String, Codable, Sendable {
    case applied
    case alreadyApplied = "already_applied"
}

public struct HelloMessage: Codable, Equatable, Sendable {
    public let type: String
    public let mode: ProtocolMode
    public let protoMin: Int
    public let protoMax: Int
    public let deviceID: String
    public let deviceName: String
    public let os: String
    public let osVersion: Int64
    public let capabilities: [String]
    public let outboxGeneration: String?
    public let connectionEpoch: Int64
    public let phoneTime: Int64
    public let attemptID: String?
    public let qrToken: String?
    public let unpairID: String?

    public init(
        mode: ProtocolMode,
        protoMin: Int,
        protoMax: Int,
        deviceID: String,
        deviceName: String,
        os: String,
        osVersion: Int64,
        capabilities: [String],
        outboxGeneration: String? = nil,
        connectionEpoch: Int64,
        phoneTime: Int64,
        attemptID: String? = nil,
        qrToken: String? = nil,
        unpairID: String? = nil
    ) {
        self.type = "hello"
        self.mode = mode
        self.protoMin = protoMin
        self.protoMax = protoMax
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.os = os
        self.osVersion = osVersion
        self.capabilities = capabilities
        self.outboxGeneration = outboxGeneration
        self.connectionEpoch = connectionEpoch
        self.phoneTime = phoneTime
        self.attemptID = attemptID
        self.qrToken = qrToken
        self.unpairID = unpairID
    }

    enum CodingKeys: String, CodingKey {
        case type, mode
        case protoMin = "proto_min"
        case protoMax = "proto_max"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case os
        case osVersion = "os_version"
        case capabilities = "caps"
        case outboxGeneration = "outbox_gen"
        case connectionEpoch = "conn_epoch"
        case phoneTime = "phone_time"
        case attemptID = "attempt_id"
        case qrToken = "qr_token"
        case unpairID = "unpair_id"
    }
}

public struct WelcomeMessage: Codable, Equatable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let deviceID: String
    public let macName: String
    public let outboxGeneration: String
    public let cursor: Int64
    public let capabilities: [String]

    public init(
        protocolVersion: Int,
        deviceID: String,
        macName: String,
        outboxGeneration: String,
        cursor: Int64,
        capabilities: [String]
    ) {
        self.type = "welcome"
        self.protocolVersion = protocolVersion
        self.deviceID = deviceID
        self.macName = macName
        self.outboxGeneration = outboxGeneration
        self.cursor = cursor
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "proto"
        case deviceID = "device_id"
        case macName = "mac_name"
        case outboxGeneration = "outbox_gen"
        case cursor
        case capabilities = "caps"
    }
}

public struct BacklogStartMessage: Codable, Equatable, Sendable {
    public let type: String
    public let syncID: String
    public let fromSequence: Int64
    public let replayToSequence: Int64
    public let eventCount: Int64

    public init(syncID: String, fromSequence: Int64, replayToSequence: Int64, eventCount: Int64) {
        self.type = "backlog_start"
        self.syncID = syncID
        self.fromSequence = fromSequence
        self.replayToSequence = replayToSequence
        self.eventCount = eventCount
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncID = "sync_id"
        case fromSequence = "from_seq"
        case replayToSequence = "replay_to_seq"
        case eventCount = "event_count"
    }
}

public struct BacklogGapMessage: Codable, Equatable, Sendable {
    public let type: String
    public let syncID: String
    public let fromSequence: Int64
    public let toSequence: Int64
    public let reason: String

    public init(syncID: String, fromSequence: Int64, toSequence: Int64, reason: String) {
        self.type = "backlog_gap"
        self.syncID = syncID
        self.fromSequence = fromSequence
        self.toSequence = toSequence
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncID = "sync_id"
        case fromSequence = "from_seq"
        case toSequence = "to_seq"
        case reason
    }
}

public struct ActiveEntry: Codable, Equatable, Sendable {
    public let key: String
    public let contentHash: String
    public let stateSequence: Int64

    public init(key: String, contentHash: String, stateSequence: Int64) {
        self.key = key
        self.contentHash = contentHash
        self.stateSequence = stateSequence
    }

    enum CodingKeys: String, CodingKey {
        case key
        case contentHash = "h"
        case stateSequence = "state_seq"
    }
}

public struct ActiveChunkMessage: Codable, Equatable, Sendable {
    public let type: String
    public let syncID: String
    public let index: Int64
    public let final: Bool
    public let active: [ActiveEntry]

    public init(syncID: String, index: Int64, final: Bool, active: [ActiveEntry]) {
        self.type = "active_chunk"
        self.syncID = syncID
        self.index = index
        self.final = final
        self.active = active
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncID = "sync_id"
        case index, final, active
    }
}

public struct BacklogEndMessage: Codable, Equatable, Sendable {
    public let type: String
    public let syncID: String
    public let stateSequence: Int64

    public init(syncID: String, stateSequence: Int64) {
        self.type = "backlog_end"
        self.syncID = syncID
        self.stateSequence = stateSequence
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncID = "sync_id"
        case stateSequence = "state_seq"
    }
}

public struct EventApp: Codable, Equatable, Sendable {
    public let package: String
    public let label: String
    public let category: String?

    public init(package: String, label: String, category: String? = nil) {
        self.package = package
        self.label = label
        self.category = category
    }

    enum CodingKeys: String, CodingKey {
        case package = "pkg"
        case label, category
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(package, forKey: .package)
        try container.encode(label, forKey: .label)
        if let category {
            try container.encode(category, forKey: .category)
        } else {
            try container.encodeNil(forKey: .category)
        }
    }
}

public struct NotificationMessageLine: Codable, Equatable, Sendable {
    public let sender: String?
    public let text: String
    public let timestamp: Int64?

    public init(sender: String? = nil, text: String, timestamp: Int64? = nil) {
        self.sender = sender
        self.text = text
        self.timestamp = timestamp
    }

    enum CodingKeys: String, CodingKey {
        case sender, text
        case timestamp = "ts"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let sender {
            try container.encode(sender, forKey: .sender)
        } else {
            try container.encodeNil(forKey: .sender)
        }
        try container.encode(text, forKey: .text)
        if let timestamp {
            try container.encode(timestamp, forKey: .timestamp)
        } else {
            try container.encodeNil(forKey: .timestamp)
        }
    }
}

public struct NotificationContent: Codable, Equatable, Sendable {
    public let title: String?
    public let text: String?
    public let bigText: String?
    public let subText: String?
    public let infoText: String?
    public let summaryText: String?
    public let textLines: [String]?
    public let messages: [NotificationMessageLine]?
    public let isClearable: Bool
    public let isGroupSummary: Bool
    public let groupKey: String?

    public init(
        title: String? = nil,
        text: String? = nil,
        bigText: String? = nil,
        subText: String? = nil,
        infoText: String? = nil,
        summaryText: String? = nil,
        textLines: [String]? = nil,
        messages: [NotificationMessageLine]? = nil,
        isClearable: Bool = true,
        isGroupSummary: Bool = false,
        groupKey: String? = nil
    ) {
        self.title = title
        self.text = text
        self.bigText = bigText
        self.subText = subText
        self.infoText = infoText
        self.summaryText = summaryText
        self.textLines = textLines
        self.messages = messages
        self.isClearable = isClearable
        self.isGroupSummary = isGroupSummary
        self.groupKey = groupKey
    }

    enum CodingKeys: String, CodingKey {
        case title, text
        case bigText = "big_text"
        case subText = "sub_text"
        case infoText = "info_text"
        case summaryText = "summary_text"
        case textLines = "text_lines"
        case messages
        case isClearable = "is_clearable"
        case isGroupSummary = "is_group_summary"
        case groupKey = "group_key"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(title, forKey: .title)
        try container.encodeNullable(text, forKey: .text)
        try container.encodeNullable(bigText, forKey: .bigText)
        try container.encodeNullable(subText, forKey: .subText)
        try container.encodeNullable(infoText, forKey: .infoText)
        try container.encodeNullable(summaryText, forKey: .summaryText)
        try container.encodeNullable(textLines, forKey: .textLines)
        try container.encodeNullable(messages, forKey: .messages)
        try container.encode(isClearable, forKey: .isClearable)
        try container.encode(isGroupSummary, forKey: .isGroupSummary)
        try container.encodeNullable(groupKey, forKey: .groupKey)
    }

    public var displayBody: String {
        if let bigText, !bigText.isEmpty { return bigText }
        if let text, !text.isEmpty { return text }
        if let messages, let last = messages.last { return last.text }
        if let textLines, !textLines.isEmpty { return textLines.joined(separator: "\n") }
        return [subText, infoText, summaryText].compactMap { $0 }.first ?? ""
    }
}

public struct DNDState: Codable, Equatable, Sendable {
    public let filter: String
    public let suppressed: Bool

    public init(filter: String = "all", suppressed: Bool = false) {
        self.filter = filter
        self.suppressed = suppressed
    }
}

public struct EventFlags: Codable, Equatable, Sendable {
    public let replayed: Bool
    public let reconciled: Bool

    public init(replayed: Bool = false, reconciled: Bool = false) {
        self.replayed = replayed
        self.reconciled = reconciled
    }
}

public struct RemoveReason: Codable, Equatable, Sendable {
    public let code: Int64
    public let reconciled: Bool

    public init(code: Int64, reconciled: Bool) {
        self.code = code
        self.reconciled = reconciled
    }
}

public struct CaptureInterval: Codable, Equatable, Sendable {
    public let startAt: Int64?
    public let endAt: Int64?

    public init(startAt: Int64?, endAt: Int64?) {
        self.startAt = startAt
        self.endAt = endAt
    }

    enum CodingKeys: String, CodingKey {
        case startAt = "start_at"
        case endAt = "end_at"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNullable(startAt, forKey: .startAt)
        try container.encodeNullable(endAt, forKey: .endAt)
    }
}

public struct EventMessage: Codable, Equatable, Sendable {
    public let type: String
    public let syncID: String?
    public let sequence: Int64?
    public let stateSequence: Int64?
    public let requestID: String?
    public let event: EventKind
    public let key: String?
    public let postedAt: Int64?
    public let user: Int64?
    public let contentHash: String?
    public let app: EventApp?
    public let notification: NotificationContent?
    public let dnd: DNDState?
    public let flags: EventFlags
    public let truncatedFields: [String]?
    public let removeReason: RemoveReason?
    public let confidence: GapConfidence?
    public let interval: CaptureInterval?
    public let evidence: String?
    public let details: String?

    public init(
        syncID: String? = nil,
        sequence: Int64? = nil,
        stateSequence: Int64? = nil,
        requestID: String? = nil,
        event: EventKind,
        key: String? = nil,
        postedAt: Int64? = nil,
        user: Int64? = nil,
        contentHash: String? = nil,
        app: EventApp? = nil,
        notification: NotificationContent? = nil,
        dnd: DNDState? = nil,
        flags: EventFlags = EventFlags(),
        truncatedFields: [String]? = nil,
        removeReason: RemoveReason? = nil,
        confidence: GapConfidence? = nil,
        interval: CaptureInterval? = nil,
        evidence: String? = nil,
        details: String? = nil
    ) {
        self.type = "event"
        self.syncID = syncID
        self.sequence = sequence
        self.stateSequence = stateSequence
        self.requestID = requestID
        self.event = event
        self.key = key
        self.postedAt = postedAt
        self.user = user
        self.contentHash = contentHash
        self.app = app
        self.notification = notification
        self.dnd = dnd
        self.flags = flags
        self.truncatedFields = truncatedFields
        self.removeReason = removeReason
        self.confidence = confidence
        self.interval = interval
        self.evidence = evidence
        self.details = details
    }

    enum CodingKeys: String, CodingKey {
        case type
        case syncID = "sync_id"
        case sequence = "seq"
        case stateSequence = "state_seq"
        case requestID = "request_id"
        case event = "ev"
        case key
        case postedAt = "posted_at"
        case user
        case contentHash = "h"
        case app
        case notification = "n"
        case dnd, flags
        case truncatedFields = "truncated_fields"
        case removeReason = "remove_reason"
        case confidence, interval, evidence, details
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(syncID, forKey: .syncID)
        try container.encodeIfPresent(sequence, forKey: .sequence)
        try container.encodeIfPresent(stateSequence, forKey: .stateSequence)
        try container.encodeIfPresent(requestID, forKey: .requestID)
        try container.encode(event, forKey: .event)
        try container.encodeIfPresent(key, forKey: .key)
        try container.encodeIfPresent(postedAt, forKey: .postedAt)
        try container.encodeIfPresent(user, forKey: .user)
        try container.encodeNullable(contentHash, forKey: .contentHash)
        try container.encodeIfPresent(app, forKey: .app)
        try container.encodeIfPresent(notification, forKey: .notification)
        try container.encodeIfPresent(dnd, forKey: .dnd)
        try container.encode(flags, forKey: .flags)
        try container.encodeIfPresent(truncatedFields, forKey: .truncatedFields)
        try container.encodeIfPresent(removeReason, forKey: .removeReason)
        try container.encodeIfPresent(confidence, forKey: .confidence)
        try container.encodeIfPresent(interval, forKey: .interval)
        try container.encodeIfPresent(evidence, forKey: .evidence)
        try container.encodeIfPresent(details, forKey: .details)
    }
}

public struct AckMessage: Codable, Equatable, Sendable {
    public let type: String
    public let sequence: Int64

    public init(sequence: Int64) {
        self.type = "ack"
        self.sequence = sequence
    }

    enum CodingKeys: String, CodingKey {
        case type
        case sequence = "seq"
    }
}

public struct PingMessage: Codable, Equatable, Sendable {
    public let type: String
    public let pingID: String
    public let phoneTime: Int64

    public init(pingID: String, phoneTime: Int64) {
        self.type = "ping"
        self.pingID = pingID
        self.phoneTime = phoneTime
    }

    enum CodingKeys: String, CodingKey {
        case type
        case pingID = "ping_id"
        case phoneTime = "phone_time"
    }
}

public struct PongMessage: Codable, Equatable, Sendable {
    public let type: String
    public let pingID: String
    public let phoneTime: Int64
    public let macTime: Int64

    public init(pingID: String, phoneTime: Int64, macTime: Int64) {
        self.type = "pong"
        self.pingID = pingID
        self.phoneTime = phoneTime
        self.macTime = macTime
    }

    enum CodingKeys: String, CodingKey {
        case type
        case pingID = "ping_id"
        case phoneTime = "phone_time"
        case macTime = "mac_time"
    }
}

public struct DismissMessage: Codable, Equatable, Sendable {
    public let type: String
    public let key: String

    public init(key: String) {
        self.type = "dismiss"
        self.key = key
    }
}

public struct FetchMessage: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let keys: [String]

    public init(requestID: String, keys: [String]) {
        self.type = "fetch"
        self.requestID = requestID
        self.keys = keys
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case keys
    }
}

public struct FetchMissingMessage: Codable, Equatable, Sendable {
    public let type: String
    public let requestID: String
    public let key: String
    public let stateSequence: Int64

    public init(requestID: String, key: String, stateSequence: Int64) {
        self.type = "fetch_missing"
        self.requestID = requestID
        self.key = key
        self.stateSequence = stateSequence
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestID = "request_id"
        case key
        case stateSequence = "state_seq"
    }
}

public struct ErrorMessage: Codable, Equatable, Sendable {
    public let type: String
    public let code: String
    public let fatal: Bool
    public let message: String?

    public init(code: String, fatal: Bool = true, message: String? = nil) {
        self.type = "error"
        self.code = code
        self.fatal = fatal
        self.message = message
    }
}

public struct PairRequestMessage: Codable, Equatable, Sendable {
    public let type: String
    public let attemptID: String
    public let role: PairRole
    public let method: PairMethod
    public let deviceID: String
    public let deviceName: String
    public let certificateDER: String

    public init(
        attemptID: String,
        role: PairRole,
        method: PairMethod,
        deviceID: String,
        deviceName: String,
        certificateDER: String
    ) {
        self.type = "pair_request"
        self.attemptID = attemptID
        self.role = role
        self.method = method
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.certificateDER = certificateDER
    }

    enum CodingKeys: String, CodingKey {
        case type
        case attemptID = "attempt_id"
        case role, method
        case deviceID = "device_id"
        case deviceName = "device_name"
        case certificateDER = "cert_der"
    }
}

public struct PairCommitMessage: Codable, Equatable, Sendable {
    public let type: String
    public let attemptID: String
    public let deviceID: String
    public let commitment: String

    public init(attemptID: String, deviceID: String, commitment: String) {
        self.type = "pair_commit"
        self.attemptID = attemptID
        self.deviceID = deviceID
        self.commitment = commitment
    }

    enum CodingKeys: String, CodingKey {
        case type
        case attemptID = "attempt_id"
        case deviceID = "device_id"
        case commitment
    }
}

public struct PairRevealMessage: Codable, Equatable, Sendable {
    public let type: String
    public let attemptID: String
    public let deviceID: String
    public let nonce: String

    public init(attemptID: String, deviceID: String, nonce: String) {
        self.type = "pair_reveal"
        self.attemptID = attemptID
        self.deviceID = deviceID
        self.nonce = nonce
    }

    enum CodingKeys: String, CodingKey {
        case type
        case attemptID = "attempt_id"
        case deviceID = "device_id"
        case nonce
    }
}

public struct PairResultMessage: Codable, Equatable, Sendable {
    public let type: String
    public let attemptID: String
    public let deviceID: String
    public let transcriptHash: String
    public let result: PairResultKind
    public let reason: PairRejectReason?
    public let outboxGeneration: String?
    public let initialCursor: Int64?

    public init(
        attemptID: String,
        deviceID: String,
        transcriptHash: String,
        result: PairResultKind,
        reason: PairRejectReason? = nil,
        outboxGeneration: String? = nil,
        initialCursor: Int64? = nil
    ) {
        self.type = "pair_result"
        self.attemptID = attemptID
        self.deviceID = deviceID
        self.transcriptHash = transcriptHash
        self.result = result
        self.reason = reason
        self.outboxGeneration = outboxGeneration
        self.initialCursor = initialCursor
    }

    enum CodingKeys: String, CodingKey {
        case type
        case attemptID = "attempt_id"
        case deviceID = "device_id"
        case transcriptHash = "transcript_hash"
        case result, reason
        case outboxGeneration = "outbox_gen"
        case initialCursor = "initial_cursor"
    }
}

public struct UnpairMessage: Codable, Equatable, Sendable {
    public let type: String
    public let unpairID: String
    public let initiatorID: String
    public let peerID: String
    public let reason: UnpairReason

    public init(unpairID: String, initiatorID: String, peerID: String, reason: UnpairReason) {
        self.type = "unpair"
        self.unpairID = unpairID
        self.initiatorID = initiatorID
        self.peerID = peerID
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case type
        case unpairID = "unpair_id"
        case initiatorID = "initiator_id"
        case peerID = "peer_id"
        case reason
    }
}

public struct UnpairAckMessage: Codable, Equatable, Sendable {
    public let type: String
    public let unpairID: String
    public let initiatorID: String
    public let peerID: String
    public let status: UnpairStatus

    public init(unpairID: String, initiatorID: String, peerID: String, status: UnpairStatus) {
        self.type = "unpair_ack"
        self.unpairID = unpairID
        self.initiatorID = initiatorID
        self.peerID = peerID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case type
        case unpairID = "unpair_id"
        case initiatorID = "initiator_id"
        case peerID = "peer_id"
        case status
    }
}

public enum WireMessage: Equatable, Sendable {
    case hello(HelloMessage)
    case welcome(WelcomeMessage)
    case backlogStart(BacklogStartMessage)
    case backlogGap(BacklogGapMessage)
    case activeChunk(ActiveChunkMessage)
    case backlogEnd(BacklogEndMessage)
    case event(EventMessage)
    case ack(AckMessage)
    case ping(PingMessage)
    case pong(PongMessage)
    case dismiss(DismissMessage)
    case fetch(FetchMessage)
    case fetchMissing(FetchMissingMessage)
    case error(ErrorMessage)
    case pairRequest(PairRequestMessage)
    case pairCommit(PairCommitMessage)
    case pairReveal(PairRevealMessage)
    case pairResult(PairResultMessage)
    case unpair(UnpairMessage)
    case unpairAck(UnpairAckMessage)
    case unknown(type: String, payload: Data)

    public var type: String {
        switch self {
        case .hello: return "hello"
        case .welcome: return "welcome"
        case .backlogStart: return "backlog_start"
        case .backlogGap: return "backlog_gap"
        case .activeChunk: return "active_chunk"
        case .backlogEnd: return "backlog_end"
        case .event: return "event"
        case .ack: return "ack"
        case .ping: return "ping"
        case .pong: return "pong"
        case .dismiss: return "dismiss"
        case .fetch: return "fetch"
        case .fetchMissing: return "fetch_missing"
        case .error: return "error"
        case .pairRequest: return "pair_request"
        case .pairCommit: return "pair_commit"
        case .pairReveal: return "pair_reveal"
        case .pairResult: return "pair_result"
        case .unpair: return "unpair"
        case .unpairAck: return "unpair_ack"
        case .unknown(let type, _): return type
        }
    }
}

private extension KeyedEncodingContainer {
    mutating func encodeNullable<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
