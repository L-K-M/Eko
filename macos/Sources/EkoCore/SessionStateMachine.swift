import Foundation

public enum SessionPhase: Equatable, Sendable {
    case awaitingBacklog
    case backlog(syncID: String)
    case live
    case closed
}

public struct BacklogCompletion: Equatable, Sendable {
    public let syncID: String
    public let stateSequence: Int64
    public let activeEntries: [ActiveEntry]
    public let receivedEventCount: Int64
}

public enum SessionAction: Equatable, Sendable {
    case ingestEvent(EventMessage)
    case ingestGap(BacklogGapMessage)
    case activeProgress
    case backlogCompleted(BacklogCompletion)
    case applyFetchEvent(EventMessage)
    case applyFetchMissing(FetchMissingMessage)
    case replyPong(pingID: String, phoneTime: Int64)
    case unpair(UnpairMessage)
    case unpairAcknowledged(UnpairAckMessage)
    case peerError(ErrorMessage)
    case ignoreExtension(String)
}

public struct SessionStateMachine: Sendable {
    public private(set) var phase: SessionPhase = .awaitingBacklog
    public private(set) var processedThrough: Int64
    public let generation: String
    public let negotiatedCapabilities: Set<String>

    private var syncID: String?
    private var replayToSequence: Int64 = 0
    private var declaredFromSequence: Int64 = 0
    private var declaredEventCount: Int64 = 0
    private var receivedEventCount: Int64 = 0
    private var nextExpectedSequence: Int64
    private var firstEventSeen = false
    private var nextActiveChunkIndex: Int64 = 0
    private var activeSnapshotFinished = false
    private var activeEntries: [ActiveEntry] = []
    private var activeKeys: Set<String> = []
    private var fetchRequestID: String?
    private var pendingFetchKeys: [String] = []

    public init(cursor: Int64, generation: String, negotiatedCapabilities: Set<String>) {
        self.processedThrough = cursor
        self.nextExpectedSequence = cursor + 1
        self.generation = generation
        self.negotiatedCapabilities = negotiatedCapabilities
    }

    public var hasOutstandingFetch: Bool { fetchRequestID != nil }

    public mutating func beginFetch(_ fetch: FetchMessage) throws {
        guard phase == .live, fetchRequestID == nil else {
            throw EkoCoreError.invalidState("only one fetch request may be outstanding")
        }
        fetchRequestID = fetch.requestID
        pendingFetchKeys = fetch.keys
    }

    public mutating func accept(_ message: WireMessage) throws -> SessionAction? {
        switch message {
        case .backlogStart(let start):
            guard phase == .awaitingBacklog else {
                throw EkoCoreError.invalidState("backlog_start is not the first sync frame")
            }
            guard start.replayToSequence >= processedThrough,
                  start.fromSequence >= processedThrough + 1,
                  start.fromSequence <= start.replayToSequence + 1 else {
                throw EkoCoreError.invalidState("backlog_start does not cover the durable cursor")
            }
            phase = .backlog(syncID: start.syncID)
            syncID = start.syncID
            replayToSequence = start.replayToSequence
            declaredFromSequence = start.fromSequence
            declaredEventCount = start.eventCount
            nextExpectedSequence = processedThrough + 1
            return nil

        case .backlogGap(let gap):
            guard case .backlog(let activeSyncID) = phase,
                  gap.syncID == activeSyncID,
                  !firstEventSeen,
                  !activeSnapshotFinished,
                  gap.fromSequence == nextExpectedSequence,
                  gap.toSequence <= replayToSequence else {
                throw EkoCoreError.invalidState("backlog_gap is out of order")
            }
            nextExpectedSequence = gap.toSequence + 1
            processedThrough = gap.toSequence
            return .ingestGap(gap)

        case .event(let event):
            if event.sequence == nil {
                guard event.stateSequence != nil, phase == .live,
                      let requestID = event.requestID, requestID == fetchRequestID,
                      let key = event.key, pendingFetchKeys.first == key else {
                    throw EkoCoreError.invalidState("fetch response arrived outside live state")
                }
                pendingFetchKeys.removeFirst()
                completeFetchIfNeeded()
                return .applyFetchEvent(event)
            }
            guard let sequence = event.sequence else {
                throw EkoCoreError.invalidState("event lacks sequence metadata")
            }
            switch phase {
            case .backlog:
                guard !activeSnapshotFinished,
                      event.flags.replayed,
                      event.syncID == syncID,
                      sequence == nextExpectedSequence,
                      sequence <= replayToSequence else {
                    throw EkoCoreError.invalidState("replayed event is out of order")
                }
                if !firstEventSeen {
                    guard sequence == declaredFromSequence else {
                        throw EkoCoreError.invalidState("first replayed event does not match from_seq")
                    }
                    firstEventSeen = true
                }
                receivedEventCount += 1
                guard receivedEventCount <= declaredEventCount else {
                    throw EkoCoreError.invalidState("backlog contains more events than declared")
                }
                nextExpectedSequence = sequence + 1
                processedThrough = sequence
                return .ingestEvent(event)

            case .live:
                guard !event.flags.replayed, sequence == processedThrough + 1 else {
                    throw EkoCoreError.invalidState("live event is out of order")
                }
                processedThrough = sequence
                nextExpectedSequence = sequence + 1
                return .ingestEvent(event)

            case .awaitingBacklog, .closed:
                throw EkoCoreError.invalidState("event arrived outside an active stream")
            }

        case .activeChunk(let chunk):
            guard case .backlog(let activeSyncID) = phase,
                  chunk.syncID == activeSyncID,
                  !activeSnapshotFinished,
                  nextExpectedSequence == replayToSequence + 1,
                  receivedEventCount == declaredEventCount,
                  chunk.index == nextActiveChunkIndex else {
                throw EkoCoreError.invalidState("active_chunk is out of order")
            }
            activeEntries.append(contentsOf: chunk.active)
            guard activeEntries.count <= ProtocolLimits.maximumActiveSnapshotEntries else {
                throw EkoCoreError.protocolViolation("active snapshot exceeds the total entry bound")
            }
            for entry in chunk.active {
                guard activeKeys.insert(entry.key).inserted,
                      entry.stateSequence <= replayToSequence else {
                    throw EkoCoreError.invalidState("active snapshot has duplicate or future state")
                }
            }
            nextActiveChunkIndex += 1
            activeSnapshotFinished = chunk.final
            return .activeProgress

        case .backlogEnd(let end):
            guard case .backlog(let activeSyncID) = phase,
                  end.syncID == activeSyncID,
                  end.stateSequence == replayToSequence,
                  nextExpectedSequence == replayToSequence + 1,
                  receivedEventCount == declaredEventCount,
                  activeSnapshotFinished else {
                throw EkoCoreError.invalidState("backlog_end arrived before complete coverage and snapshot")
            }
            let completion = BacklogCompletion(
                syncID: activeSyncID,
                stateSequence: end.stateSequence,
                activeEntries: activeEntries,
                receivedEventCount: receivedEventCount
            )
            phase = .live
            processedThrough = end.stateSequence
            return .backlogCompleted(completion)

        case .fetchMissing(let missing):
            guard phase == .live, missing.requestID == fetchRequestID,
                  pendingFetchKeys.first == missing.key else {
                throw EkoCoreError.invalidState("fetch_missing arrived outside live state")
            }
            pendingFetchKeys.removeFirst()
            completeFetchIfNeeded()
            return .applyFetchMissing(missing)

        case .ping(let ping):
            return .replyPong(pingID: ping.pingID, phoneTime: ping.phoneTime)

        case .pong:
            throw EkoCoreError.invalidState("pong is not valid from phone to Mac")

        case .unpair(let message):
            guard phase != .closed else { throw EkoCoreError.invalidState("unpair arrived after close") }
            return .unpair(message)

        case .unpairAck(let message):
            guard phase != .closed else { throw EkoCoreError.invalidState("unpair_ack arrived after close") }
            return .unpairAcknowledged(message)

        case .error(let error):
            return .peerError(error)

        case .unknown(let type, _):
            guard negotiatedCapabilities.contains("ext_types") else {
                throw EkoCoreError.protocolViolation("unknown message type was not negotiated: \(type)")
            }
            return .ignoreExtension(type)

        case .hello, .welcome, .ack, .dismiss, .fetch, .pairRequest, .pairCommit, .pairReveal, .pairResult:
            throw EkoCoreError.invalidState("unexpected inbound message type: \(message.type)")
        }
    }

    public mutating func close() {
        phase = .closed
        activeEntries.removeAll(keepingCapacity: false)
        activeKeys.removeAll(keepingCapacity: false)
        fetchRequestID = nil
        pendingFetchKeys.removeAll(keepingCapacity: false)
    }

    private mutating func completeFetchIfNeeded() {
        guard pendingFetchKeys.isEmpty else { return }
        fetchRequestID = nil
    }
}

public actor SessionEpochRegistry {
    public struct Admission: Equatable, Sendable {
        public let displacedConnectionID: UUID?
    }

    private struct Entry {
        let epoch: Int64
        let connectionID: UUID
    }

    private var entries: [String: Entry] = [:]

    public init() {}

    public func admit(deviceID: String, epoch: Int64, connectionID: UUID) throws -> Admission {
        if let current = entries[deviceID] {
            guard epoch > current.epoch else { throw EkoCoreError.superseded }
            entries[deviceID] = Entry(epoch: epoch, connectionID: connectionID)
            return Admission(displacedConnectionID: current.connectionID)
        }
        entries[deviceID] = Entry(epoch: epoch, connectionID: connectionID)
        return Admission(displacedConnectionID: nil)
    }

    public func release(deviceID: String, connectionID: UUID) {
        guard entries[deviceID]?.connectionID == connectionID else { return }
        entries.removeValue(forKey: deviceID)
    }
}
