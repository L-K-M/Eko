import Foundation

public enum ProtocolLimits {
    public static let maximumFrameLength = 1_048_576
    public static let maximumUInt53: Int64 = 9_007_199_254_740_991
    public static let maximumKeyBytes = 8_192
    public static let maximumDisplayNameScalars = 256
    public static let maximumCapabilities = 64
    public static let maximumActiveEntriesPerChunk = 4_096
    public static let maximumFetchKeys = 128
}

public enum ProtocolCodec {
    private struct Envelope: Decodable {
        let type: String
    }

    private static let gapReasons = ["retention_count", "retention_age", "peer_cursor_regressed"]
    private static let dndFilters = ["unknown", "all", "priority", "none", "alarms"]
    private static let captureEvidence = ["listener_disconnected", "process_exit", "writer_overflow"]
    private static let errorCodes = [
        "protocol_error", "incompatible", "superseded", "unpaired", "stale_generation",
        "pairing_expired", "pairing_rejected", "unauthorized", "invalid_ack", "invalid_state",
        "sequence_conflict", "frame_too_large", "store_reset",
    ]

    public static func decode(_ data: Data) throws -> WireMessage {
        guard !data.isEmpty, data.count <= ProtocolLimits.maximumFrameLength - 1 else {
            throw EkoCoreError.frameTooLarge
        }
        guard !data.starts(with: [0xEF, 0xBB, 0xBF]) else {
            throw EkoCoreError.protocolViolation("UTF-8 BOM is forbidden")
        }
        guard String(data: data, encoding: .utf8) != nil else {
            throw EkoCoreError.protocolViolation("JSON payload is not valid UTF-8")
        }
        try JSONDuplicateKeyValidator.validate(data)

        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw EkoCoreError.protocolViolation("top-level JSON value must be an object")
            }
            object = decoded
        } catch let error as EkoCoreError {
            throw error
        } catch {
            throw EkoCoreError.protocolViolation("invalid JSON: \(error.localizedDescription)")
        }

        let decoder = JSONDecoder()
        let envelope: Envelope
        do {
            envelope = try decoder.decode(Envelope.self, from: data)
        } catch {
            throw EkoCoreError.protocolViolation("invalid JSON envelope: \(error.localizedDescription)")
        }

        let message: WireMessage
        do {
            switch envelope.type {
            case "hello": message = .hello(try decoder.decode(HelloMessage.self, from: data))
            case "welcome": message = .welcome(try decoder.decode(WelcomeMessage.self, from: data))
            case "backlog_start": message = .backlogStart(try decoder.decode(BacklogStartMessage.self, from: data))
            case "backlog_gap": message = .backlogGap(try decoder.decode(BacklogGapMessage.self, from: data))
            case "active_chunk": message = .activeChunk(try decoder.decode(ActiveChunkMessage.self, from: data))
            case "backlog_end": message = .backlogEnd(try decoder.decode(BacklogEndMessage.self, from: data))
            case "event": message = .event(try decoder.decode(EventMessage.self, from: data))
            case "ack": message = .ack(try decoder.decode(AckMessage.self, from: data))
            case "ping": message = .ping(try decoder.decode(PingMessage.self, from: data))
            case "pong": message = .pong(try decoder.decode(PongMessage.self, from: data))
            case "dismiss": message = .dismiss(try decoder.decode(DismissMessage.self, from: data))
            case "fetch": message = .fetch(try decoder.decode(FetchMessage.self, from: data))
            case "fetch_missing": message = .fetchMissing(try decoder.decode(FetchMissingMessage.self, from: data))
            case "error": message = .error(try decoder.decode(ErrorMessage.self, from: data))
            case "pair_request": message = .pairRequest(try decoder.decode(PairRequestMessage.self, from: data))
            case "pair_commit": message = .pairCommit(try decoder.decode(PairCommitMessage.self, from: data))
            case "pair_reveal": message = .pairReveal(try decoder.decode(PairRevealMessage.self, from: data))
            case "pair_result": message = .pairResult(try decoder.decode(PairResultMessage.self, from: data))
            case "unpair": message = .unpair(try decoder.decode(UnpairMessage.self, from: data))
            case "unpair_ack": message = .unpairAck(try decoder.decode(UnpairAckMessage.self, from: data))
            default: message = .unknown(type: envelope.type, payload: data)
            }
        } catch let error as EkoCoreError {
            throw error
        } catch {
            throw EkoCoreError.protocolViolation("invalid \(envelope.type) message: \(error.localizedDescription)")
        }

        try validate(message, object: object)
        return message
    }

    public static func encode(_ message: WireMessage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        switch message {
        case .hello(let value): data = try encoder.encode(value)
        case .welcome(let value): data = try encoder.encode(value)
        case .backlogStart(let value): data = try encoder.encode(value)
        case .backlogGap(let value): data = try encoder.encode(value)
        case .activeChunk(let value): data = try encoder.encode(value)
        case .backlogEnd(let value): data = try encoder.encode(value)
        case .event(let value): data = try encoder.encode(value)
        case .ack(let value): data = try encoder.encode(value)
        case .ping(let value): data = try encoder.encode(value)
        case .pong(let value): data = try encoder.encode(value)
        case .dismiss(let value): data = try encoder.encode(value)
        case .fetch(let value): data = try encoder.encode(value)
        case .fetchMissing(let value): data = try encoder.encode(value)
        case .error(let value): data = try encoder.encode(value)
        case .pairRequest(let value): data = try encoder.encode(value)
        case .pairCommit(let value): data = try encoder.encode(value)
        case .pairReveal(let value): data = try encoder.encode(value)
        case .pairResult(let value): data = try encoder.encode(value)
        case .unpair(let value): data = try encoder.encode(value)
        case .unpairAck(let value): data = try encoder.encode(value)
        case .unknown:
            throw EkoCoreError.invalidData("unknown extension messages are receive-only")
        }
        _ = try decode(data)
        return data
    }

    private static func validate(_ message: WireMessage, object: [String: Any]) throws {
        switch message {
        case .hello(let hello):
            guard hello.type == "hello", hello.protoMin == 1, hello.protoMax == 1,
                  hello.deviceID.isLowercaseSHA256, validDisplayName(hello.deviceName),
                  hello.os == "android", isUInt32(hello.osVersion),
                  validCapabilities(hello.capabilities), isPositiveUInt53(hello.connectionEpoch),
                  isUInt53(hello.phoneTime) else {
                throw EkoCoreError.protocolViolation("hello fields are invalid")
            }
            switch hello.mode {
            case .normal:
                guard let generation = hello.outboxGeneration, isUUIDv4(generation),
                      hello.capabilities.contains("notif"), hello.attemptID == nil,
                      hello.qrToken == nil, hello.unpairID == nil,
                      !object.keys.contains("attempt_id"), !object.keys.contains("qr_token"),
                      !object.keys.contains("unpair_id") else {
                    throw EkoCoreError.protocolViolation("normal hello has invalid mode fields")
                }
            case .pair:
                guard let generation = hello.outboxGeneration, isUUIDv4(generation),
                      let attemptID = hello.attemptID, isPairAttemptID(attemptID),
                      hello.capabilities.contains("notif"), hello.unpairID == nil,
                      !object.keys.contains("unpair_id"),
                      hello.qrToken.map({ isQRToken($0) }) ?? !object.keys.contains("qr_token") else {
                    throw EkoCoreError.protocolViolation("pair hello has invalid mode fields")
                }
            case .unpair:
                guard let unpairID = hello.unpairID, isUUIDv4(unpairID),
                      hello.outboxGeneration == nil, hello.attemptID == nil, hello.qrToken == nil,
                      !object.keys.contains("outbox_gen"), !object.keys.contains("attempt_id"),
                      !object.keys.contains("qr_token") else {
                    throw EkoCoreError.protocolViolation("unpair hello has invalid mode fields")
                }
            }

        case .welcome(let welcome):
            guard welcome.type == "welcome", welcome.protocolVersion == 1,
                  welcome.deviceID.isLowercaseSHA256, validDisplayName(welcome.macName),
                  isUUIDv4(welcome.outboxGeneration), isUInt53(welcome.cursor),
                  validCapabilities(welcome.capabilities), welcome.capabilities.contains("notif") else {
                throw EkoCoreError.protocolViolation("welcome is invalid")
            }

        case .backlogStart(let start):
            guard isUUIDv4(start.syncID), isPositiveUInt53(start.fromSequence),
                  isUInt53(start.replayToSequence), isUInt53(start.eventCount) else {
                throw EkoCoreError.protocolViolation("backlog_start has invalid bounds")
            }

        case .backlogGap(let gap):
            guard isUUIDv4(gap.syncID), isPositiveUInt53(gap.fromSequence),
                  isPositiveUInt53(gap.toSequence), gap.toSequence >= gap.fromSequence,
                  gapReasons.contains(gap.reason) else {
                throw EkoCoreError.protocolViolation("backlog_gap has invalid bounds")
            }

        case .activeChunk(let chunk):
            guard isUUIDv4(chunk.syncID), isUInt53(chunk.index),
                  chunk.active.count <= ProtocolLimits.maximumActiveEntriesPerChunk,
                  Set(chunk.active.map(\.key)).count == chunk.active.count else {
                throw EkoCoreError.protocolViolation("active_chunk is invalid")
            }
            for entry in chunk.active {
                guard validKey(entry.key), entry.contentHash.isLowercaseSHA256,
                      isPositiveUInt53(entry.stateSequence) else {
                    throw EkoCoreError.protocolViolation("active entry is invalid")
                }
            }

        case .backlogEnd(let end):
            guard isUUIDv4(end.syncID), isUInt53(end.stateSequence) else {
                throw EkoCoreError.protocolViolation("backlog_end is invalid")
            }

        case .event(let event):
            try validateEvent(event, object: object)

        case .ack(let ack):
            guard isPositiveUInt53(ack.sequence) else {
                throw EkoCoreError.protocolViolation("ack seq must be a positive uint53")
            }

        case .ping(let ping):
            guard isUUIDv4(ping.pingID), isUInt53(ping.phoneTime) else {
                throw EkoCoreError.protocolViolation("ping is invalid")
            }

        case .pong(let pong):
            guard isUUIDv4(pong.pingID), isUInt53(pong.phoneTime), isUInt53(pong.macTime) else {
                throw EkoCoreError.protocolViolation("pong is invalid")
            }

        case .dismiss(let dismiss):
            guard validKey(dismiss.key) else {
                throw EkoCoreError.protocolViolation("dismiss key is invalid")
            }

        case .fetch(let fetch):
            guard isUUIDv4(fetch.requestID), !fetch.keys.isEmpty,
                  fetch.keys.count <= ProtocolLimits.maximumFetchKeys,
                  Set(fetch.keys).count == fetch.keys.count,
                  fetch.keys.allSatisfy({ validKey($0) }) else {
                throw EkoCoreError.protocolViolation("fetch is invalid")
            }

        case .fetchMissing(let missing):
            guard isUUIDv4(missing.requestID), validKey(missing.key), isUInt53(missing.stateSequence) else {
                throw EkoCoreError.protocolViolation("fetch_missing is invalid")
            }

        case .pairRequest(let request):
            guard isPairAttemptID(request.attemptID), request.deviceID.isLowercaseSHA256,
                  validDisplayName(request.deviceName),
                  let certificate = Data(base64Encoded: request.certificateDER), !certificate.isEmpty,
                  certificate.base64EncodedString() == request.certificateDER,
                  EkoCrypto.fingerprint(of: certificate) == request.deviceID else {
                throw EkoCoreError.protocolViolation("pair_request is invalid")
            }

        case .pairCommit(let commit):
            guard isPairAttemptID(commit.attemptID), commit.deviceID.isLowercaseSHA256,
                  commit.commitment.isLowercaseSHA256 else {
                throw EkoCoreError.protocolViolation("pair_commit is invalid")
            }

        case .pairReveal(let reveal):
            guard isPairAttemptID(reveal.attemptID), reveal.deviceID.isLowercaseSHA256,
                  reveal.nonce.isLowercaseSHA256 else {
                throw EkoCoreError.protocolViolation("pair_reveal is invalid")
            }

        case .pairResult(let result):
            guard isPairAttemptID(result.attemptID), result.deviceID.isLowercaseSHA256,
                  result.transcriptHash.isLowercaseSHA256 else {
                throw EkoCoreError.protocolViolation("pair_result identity is invalid")
            }
            switch result.result {
            case .accept:
                guard result.reason == nil, result.outboxGeneration == nil, result.initialCursor == nil,
                      !object.keys.contains("reason"), !object.keys.contains("outbox_gen"),
                      !object.keys.contains("initial_cursor") else {
                    throw EkoCoreError.protocolViolation("accept result has forbidden fields")
                }
            case .reject:
                guard result.reason != nil, result.outboxGeneration == nil, result.initialCursor == nil,
                      !object.keys.contains("outbox_gen"), !object.keys.contains("initial_cursor") else {
                    throw EkoCoreError.protocolViolation("reject result is invalid")
                }
            case .ready, .confirmed:
                guard result.reason == nil, let generation = result.outboxGeneration,
                      isUUIDv4(generation), let cursor = result.initialCursor, isUInt53(cursor),
                      !object.keys.contains("reason") else {
                    throw EkoCoreError.protocolViolation("completion result is invalid")
                }
            }

        case .unpair(let value):
            guard isUUIDv4(value.unpairID), value.initiatorID.isLowercaseSHA256,
                  value.peerID.isLowercaseSHA256, value.initiatorID != value.peerID else {
                throw EkoCoreError.protocolViolation("unpair is invalid")
            }

        case .unpairAck(let value):
            guard isUUIDv4(value.unpairID), value.initiatorID.isLowercaseSHA256,
                  value.peerID.isLowercaseSHA256, value.initiatorID != value.peerID else {
                throw EkoCoreError.protocolViolation("unpair_ack is invalid")
            }

        case .error(let value):
            guard errorCodes.contains(value.code),
                  value.message != nil || !object.keys.contains("message"),
                  (value.message?.unicodeScalars.count ?? 0) <= 2_048 else {
                throw EkoCoreError.protocolViolation("error is invalid")
            }

        case .unknown:
            break
        }
    }

    private static func validateEvent(_ event: EventMessage, object: [String: Any]) throws {
        let fields = Set(object.keys)
        guard event.type == "event", fields.contains("h"), fields.contains("flags"),
              let rawFlags = object["flags"] as? [String: Any],
              rawFlags.keys.contains("replayed"), rawFlags.keys.contains("reconciled") else {
            throw EkoCoreError.protocolViolation("event is missing required fields")
        }
        if event.flags.replayed {
            guard let syncID = event.syncID, isUUIDv4(syncID) else {
                throw EkoCoreError.protocolViolation("replayed event requires sync_id")
            }
        } else if event.syncID != nil || fields.contains("sync_id") {
            throw EkoCoreError.protocolViolation("non-replayed event must not carry sync_id")
        }

        if let sequence = event.sequence {
            guard isPositiveUInt53(sequence), event.stateSequence == nil, event.requestID == nil,
                  !fields.contains("state_seq"), !fields.contains("request_id") else {
                throw EkoCoreError.protocolViolation("sequenced event has fetch metadata")
            }
            switch event.event {
            case .posted, .updated:
                try validateNotificationEvent(event, object: object)
                try requireAbsent(fields, ["remove_reason", "confidence", "interval", "evidence", "details"])
            case .removed:
                guard event.contentHash == nil, event.notification == nil,
                      let key = event.key, validKey(key), event.postedAt.map({ isUInt53($0) }) == true,
                      event.user.map({ isUInt32($0) }) == true, event.app != nil, event.dnd != nil,
                      event.truncatedFields != nil, event.removeReason != nil else {
                    throw EkoCoreError.protocolViolation("removed event is invalid")
                }
                try validateApp(event.app, object: object)
                try validateDND(event.dnd)
                try validateTruncatedFields(event.truncatedFields)
                guard let reason = event.removeReason, reason.code >= 0, reason.code <= 2_147_483_647,
                      let rawReason = object["remove_reason"] as? [String: Any],
                      rawReason.keys.contains("code"), rawReason.keys.contains("reconciled") else {
                    throw EkoCoreError.protocolViolation("remove_reason is invalid")
                }
                if reason.reconciled && !event.flags.reconciled {
                    throw EkoCoreError.protocolViolation("reconciled removal flags disagree")
                }
                try requireAbsent(fields, ["n", "confidence", "interval", "evidence", "details"])
            case .captureGap:
                guard event.contentHash == nil, !event.flags.reconciled,
                      event.confidence == .suspected, captureEvidence.contains(event.evidence ?? ""),
                      let interval = event.interval,
                      (interval.startAt != nil || interval.endAt != nil),
                      interval.startAt.map({ isUInt53($0) }) ?? true,
                      interval.endAt.map({ isUInt53($0) }) ?? true,
                      (interval.startAt == nil || interval.endAt == nil || interval.startAt! <= interval.endAt!),
                      event.details != nil || !fields.contains("details"),
                      (event.details?.unicodeScalars.count ?? 0) <= 2_048 else {
                    throw EkoCoreError.protocolViolation("capture_gap is invalid")
                }
                guard let rawInterval = object["interval"] as? [String: Any],
                      rawInterval.keys.contains("start_at"), rawInterval.keys.contains("end_at") else {
                    throw EkoCoreError.protocolViolation("capture interval is incomplete")
                }
                try requireAbsent(fields, [
                    "state_seq", "request_id", "key", "posted_at", "user", "app", "n", "dnd",
                    "truncated_fields", "remove_reason",
                ])
            }
            return
        }

        guard event.event == .posted, event.syncID == nil, !event.flags.replayed, event.flags.reconciled,
              let stateSequence = event.stateSequence, isPositiveUInt53(stateSequence),
              let requestID = event.requestID, isUUIDv4(requestID) else {
            throw EkoCoreError.protocolViolation("fetch event metadata is invalid")
        }
        try validateNotificationEvent(event, object: object)
        try requireAbsent(fields, ["seq", "remove_reason", "confidence", "interval", "evidence", "details"])
    }

    private static func validateNotificationEvent(_ event: EventMessage, object: [String: Any]) throws {
        guard let key = event.key, validKey(key), event.postedAt.map({ isUInt53($0) }) == true,
              event.user.map({ isUInt32($0) }) == true, let hash = event.contentHash, hash.isLowercaseSHA256,
              event.app != nil, event.notification != nil, event.dnd != nil,
              event.truncatedFields != nil else {
            throw EkoCoreError.protocolViolation("notification event is incomplete")
        }
        try validateApp(event.app, object: object)
        try validateContent(event.notification, object: object)
        try validateDND(event.dnd)
        try validateTruncatedFields(event.truncatedFields)
    }

    private static func validateApp(_ app: EventApp?, object: [String: Any]) throws {
        guard let app, let raw = object["app"] as? [String: Any],
              raw.keys.contains("pkg"), raw.keys.contains("label"), raw.keys.contains("category"),
              !app.package.isEmpty, app.package.utf8.count <= 512,
              !app.label.isEmpty, app.label.utf8.count <= 2_048,
              (app.category?.utf8.count ?? 0) <= 128 else {
            throw EkoCoreError.protocolViolation("event app is invalid")
        }
    }

    private static func validateDND(_ dnd: DNDState?) throws {
        guard let dnd, dndFilters.contains(dnd.filter) else {
            throw EkoCoreError.protocolViolation("event dnd is invalid")
        }
    }

    private static func validateContent(_ content: NotificationContent?, object: [String: Any]) throws {
        guard let content, let raw = object["n"] as? [String: Any] else {
            throw EkoCoreError.protocolViolation("notification body is invalid")
        }
        let required = [
            "title", "text", "big_text", "sub_text", "info_text", "summary_text", "text_lines",
            "messages", "is_clearable", "is_group_summary", "group_key",
        ]
        guard required.allSatisfy({ raw.keys.contains($0) }),
              (content.title?.utf8.count ?? 0) <= 8_192,
              (content.text?.utf8.count ?? 0) <= 8_192,
              (content.bigText?.utf8.count ?? 0) <= 65_536,
              (content.subText?.utf8.count ?? 0) <= 8_192,
              (content.infoText?.utf8.count ?? 0) <= 8_192,
              (content.summaryText?.utf8.count ?? 0) <= 8_192,
              (content.groupKey?.utf8.count ?? 0) <= 8_192,
              (content.textLines?.count ?? 0) <= 64,
              (content.messages?.count ?? 0) <= 64,
              content.textLines?.allSatisfy({ $0.utf8.count <= 8_192 }) ?? true,
              content.messages?.allSatisfy({
                  $0.text.utf8.count <= 16_384
                      && ($0.sender?.utf8.count ?? 0) <= 4_096
                      && ($0.timestamp.map({ isUInt53($0) }) ?? true)
              }) ?? true else {
            throw EkoCoreError.protocolViolation("notification body exceeds protocol limits")
        }
        let strings = [
            content.title, content.text, content.bigText, content.subText, content.infoText,
            content.summaryText, content.groupKey,
        ].compactMap { $0 }
        // Distinct statements, not one chained expression: the combined
        // reduce-plus-reduce-plus-reduce blows the type checker's budget
        // ("unable to type-check this expression in reasonable time").
        let stringBytes = strings.reduce(0) { $0 + $1.utf8.count }
        let textLineBytes = (content.textLines ?? []).reduce(0) { $0 + $1.utf8.count }
        let messageBytes = (content.messages ?? []).reduce(0) {
            $0 + ($1.sender?.utf8.count ?? 0) + $1.text.utf8.count
        }
        let aggregate = stringBytes + textLineBytes + messageBytes
        guard aggregate <= 524_288 else {
            throw EkoCoreError.protocolViolation("notification body exceeds aggregate limit")
        }
        if let messages = content.messages {
            guard let rawMessages = raw["messages"] as? [[String: Any]],
                  rawMessages.count == messages.count,
                  rawMessages.allSatisfy({
                      $0.keys.contains("sender") && $0.keys.contains("text") && $0.keys.contains("ts")
                  }) else {
                throw EkoCoreError.protocolViolation("notification message is missing required members")
            }
        }
    }

    private static func validateTruncatedFields(_ values: [String]?) throws {
        guard let values, values.count <= 256, Set(values).count == values.count,
              values.allSatisfy({ isJSONPointer($0) }) else {
            throw EkoCoreError.protocolViolation("truncated_fields is invalid")
        }
    }

    private static func requireAbsent(_ fields: Set<String>, _ forbidden: [String]) throws {
        guard fields.isDisjoint(with: Set(forbidden)) else {
            throw EkoCoreError.protocolViolation("event contains fields forbidden for its variant")
        }
    }

    private static func validKey(_ key: String) -> Bool {
        !key.isEmpty && key.utf8.count <= ProtocolLimits.maximumKeyBytes
    }

    private static func validDisplayName(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.count <= ProtocolLimits.maximumDisplayNameScalars
    }

    private static func validCapabilities(_ values: [String]) -> Bool {
        values.count <= ProtocolLimits.maximumCapabilities
            && Set(values).count == values.count
            && values.allSatisfy { value in
                guard let first = value.utf8.first, (97...122).contains(first), value.utf8.count <= 64 else {
                    return false
                }
                return value.utf8.dropFirst().allSatisfy {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 95
                }
            }
    }

    private static func isUInt53(_ value: Int64) -> Bool {
        value >= 0 && value <= ProtocolLimits.maximumUInt53
    }

    private static func isPositiveUInt53(_ value: Int64) -> Bool {
        value > 0 && value <= ProtocolLimits.maximumUInt53
    }

    private static func isUInt32(_ value: Int64) -> Bool {
        value >= 0 && value <= 4_294_967_295
    }

    static func isPairAttemptID(_ value: String) -> Bool {
        value.count == 32 && value.utf8.allSatisfy { Self.isLowercaseHex($0) }
    }

    static func isUUIDv4(_ value: String) -> Bool {
        guard value.count == 36, value[value.index(value.startIndex, offsetBy: 8)] == "-",
              value[value.index(value.startIndex, offsetBy: 13)] == "-",
              value[value.index(value.startIndex, offsetBy: 18)] == "-",
              value[value.index(value.startIndex, offsetBy: 23)] == "-",
              value[value.index(value.startIndex, offsetBy: 14)] == "4",
              "89ab".contains(value[value.index(value.startIndex, offsetBy: 19)]) else {
            return false
        }
        return value.utf8.enumerated().allSatisfy { index, byte in
            [8, 13, 18, 23].contains(index) ? byte == 45 : isLowercaseHex(byte)
        }
    }

    static func makeUUIDv4() -> String {
        UUID().uuidString.lowercased()
    }

    private static func isQRToken(_ value: String) -> Bool {
        value.utf8.count == 43 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func isJSONPointer(_ value: String) -> Bool {
        guard value.first == "/" else { return false }
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "~" {
                let next = value.index(after: index)
                guard next < value.endIndex, value[next] == "0" || value[next] == "1" else { return false }
                index = value.index(after: next)
            } else {
                index = value.index(after: index)
            }
        }
        return true
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

private struct JSONDuplicateKeyValidator {
    private static let integerFields: Set<String> = [
        "proto_min", "proto_max", "os_version", "conn_epoch", "phone_time", "proto", "cursor",
        "from_seq", "replay_to_seq", "event_count", "to_seq", "index", "state_seq", "seq",
        "posted_at", "user", "start_at", "end_at", "code", "ts", "ping_id", "mac_time",
        "initial_cursor",
    ]
    private let bytes: [UInt8]
    private var index = 0

    static func validate(_ data: Data) throws {
        var parser = Self(bytes: Array(data))
        try parser.parseValue(depth: 0, integerRequired: false)
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw EkoCoreError.protocolViolation("unexpected bytes after JSON value")
        }
    }

    private mutating func parseValue(depth: Int, integerRequired: Bool) throws {
        guard depth <= 64 else { throw EkoCoreError.protocolViolation("JSON nesting exceeds 64 levels") }
        skipWhitespace()
        guard index < bytes.count else { throw EkoCoreError.protocolViolation("truncated JSON value") }
        switch bytes[index] {
        case 0x7B: try parseObject(depth: depth + 1)
        case 0x5B: try parseArray(depth: depth + 1)
        case 0x22: _ = try parseString()
        case 0x74: try consumeLiteral("true")
        case 0x66: try consumeLiteral("false")
        case 0x6E: try consumeLiteral("null")
        case 0x2D, 0x30...0x39: try parseNumber(integerRequired: integerRequired)
        default: throw EkoCoreError.protocolViolation("invalid JSON token")
        }
    }

    private mutating func parseObject(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys = Set<String>()
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw EkoCoreError.protocolViolation("JSON object key is not a string")
            }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw EkoCoreError.protocolViolation("duplicate JSON key: \(key)")
            }
            skipWhitespace()
            guard consume(0x3A) else { throw EkoCoreError.protocolViolation("JSON object is missing ':'") }
            try parseValue(depth: depth, integerRequired: Self.integerFields.contains(key))
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw EkoCoreError.protocolViolation("JSON object is missing ','") }
        }
    }

    private mutating func parseArray(depth: Int) throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue(depth: depth, integerRequired: false)
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw EkoCoreError.protocolViolation("JSON array is missing ','") }
        }
    }

    private mutating func parseString() throws -> String {
        let start = index
        index += 1
        var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                if byte == 0x75 {
                    guard index + 4 < bytes.count,
                          bytes[(index + 1)...(index + 4)].allSatisfy(Self.isHex) else {
                        throw EkoCoreError.protocolViolation("invalid JSON Unicode escape")
                    }
                    index += 5
                } else {
                    guard [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(byte) else {
                        throw EkoCoreError.protocolViolation("invalid JSON string escape")
                    }
                    index += 1
                }
                escaped = false
                continue
            }
            if byte == 0x5C {
                escaped = true
                index += 1
                continue
            }
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start..<index])
                do {
                    return try JSONDecoder().decode(String.self, from: encoded)
                } catch {
                    throw EkoCoreError.protocolViolation("invalid JSON string")
                }
            }
            guard byte >= 0x20 else { throw EkoCoreError.protocolViolation("control byte in JSON string") }
            index += 1
        }
        throw EkoCoreError.protocolViolation("unterminated JSON string")
    }

    private mutating func parseNumber(integerRequired: Bool) throws {
        let hasSign = consume(0x2D)
        if hasSign, index == bytes.count {
            throw EkoCoreError.protocolViolation("truncated JSON number")
        }
        if consume(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw EkoCoreError.protocolViolation("JSON number has a leading zero")
            }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                throw EkoCoreError.protocolViolation("invalid JSON number")
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        var hasFractionOrExponent = false
        if consume(0x2E) {
            hasFractionOrExponent = true
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                throw EkoCoreError.protocolViolation("invalid JSON fraction")
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            hasFractionOrExponent = true
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count, (0x30...0x39).contains(bytes[index]) else {
                throw EkoCoreError.protocolViolation("invalid JSON exponent")
            }
            while index < bytes.count, (0x30...0x39).contains(bytes[index]) { index += 1 }
        }
        if integerRequired, hasSign || hasFractionOrExponent {
            throw EkoCoreError.protocolViolation("protocol integers require decimal lexical form")
        }
    }

    private mutating func consumeLiteral(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw EkoCoreError.protocolViolation("invalid JSON literal")
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    private static func isHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        self = result
    }
}
