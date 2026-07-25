import Foundation

public protocol SessionTransport: Sendable {
    var id: UUID { get }
    var remoteEndpointDescription: String { get }
    func receive() async throws -> WireMessage?
    func send(_ message: WireMessage) async throws
    func close() async
}

public protocol SessionLocalIdentity: Sendable {
    var certificateDER: Data { get }
    var fingerprint: String { get }
}

extension DeviceIdentity: SessionLocalIdentity {}

public enum DeviceConnectionState: Equatable, Sendable {
    case connecting
    case synchronizing
    case online
    case disconnected
    case failed(String)
}

public protocol SessionEventSink: Sendable {
    func connectionStateChanged(deviceID: String, state: DeviceConnectionState) async
    func sessionNegotiated(_ diagnostics: SessionDiagnostics) async
    func eventCommitted(_ outcome: IngestOutcome) async
    func backlogCompleted(_ summary: BacklogSummary) async
    func notificationRemoved(deviceID: String, key: String) async
}

public struct NullSessionEventSink: SessionEventSink {
    public init() {}
    public func connectionStateChanged(deviceID: String, state: DeviceConnectionState) async {}
    public func sessionNegotiated(_ diagnostics: SessionDiagnostics) async {}
    public func eventCommitted(_ outcome: IngestOutcome) async {}
    public func backlogCompleted(_ summary: BacklogSummary) async {}
    public func notificationRemoved(deviceID: String, key: String) async {}
}

public actor SessionManager {
    public typealias PairingApproval = @Sendable (PendingPairing) async -> Bool

    private struct ActiveSession {
        let transport: any SessionTransport
        let epoch: Int64
        let generation: String
        let capabilities: Set<String>
        var isLive: Bool
    }

    private let store: EkoStore
    private let localIdentity: any SessionLocalIdentity
    private let macName: String
    private let pairingMode: PairingModeController
    private let clock: any EkoClock
    private let sink: any SessionEventSink
    private let pairingApproval: PairingApproval
    private let protocolVersion = 1
    private let localCapabilities: Set<String> = ["notif", "dismiss", "otp_context", "ext_types"]
    private var activeSessions: [String: ActiveSession] = [:]
    private var pendingUnpairs: [String: String] = [:]

    public init(
        store: EkoStore,
        localIdentity: any SessionLocalIdentity,
        macName: String,
        pairingMode: PairingModeController,
        clock: any EkoClock = SystemEkoClock(),
        sink: any SessionEventSink = NullSessionEventSink(),
        pairingApproval: @escaping PairingApproval = { _ in false }
    ) {
        self.store = store
        self.localIdentity = localIdentity
        self.macName = macName
        self.pairingMode = pairingMode
        self.clock = clock
        self.sink = sink
        self.pairingApproval = pairingApproval
    }

    public func run(
        admission: TLSAdmission,
        peerCertificateDER: Data,
        transport: any SessionTransport
    ) async {
        var claimedDeviceID: String?
        do {
            guard admission.isAccepted else { throw EkoCoreError.unauthorized }
            guard let first = try await receiveWithTimeout(from: transport, duration: .seconds(5)),
                  case .hello(let hello) = first else {
                throw EkoCoreError.invalidState("hello must be the first application frame")
            }
            claimedDeviceID = hello.deviceID
            let fingerprint = EkoCrypto.fingerprint(of: peerCertificateDER)
            guard hello.deviceID == fingerprint else { throw EkoCoreError.unauthorized }
            let negotiatedProtocol = try negotiate(hello)

            switch (admission, hello.mode) {
            case (.paired(let admittedID), .normal) where admittedID == hello.deviceID:
                let sessionAdmission = try store.beginSession(
                    hello: hello,
                    certificateDER: peerCertificateDER,
                    negotiatedProtocol: negotiatedProtocol,
                    endpoint: transport.remoteEndpointDescription
                )
                switch sessionAdmission {
                case .started(let start):
                    try await beginNormalSession(
                        hello: hello,
                        start: start,
                        transport: transport,
                        negotiatedProtocol: negotiatedProtocol
                    )
                case .retiredGeneration:
                    throw EkoCoreError.retiredGeneration
                }

            case (.pairing(let admittedFingerprint), .pair) where admittedFingerprint == hello.deviceID:
                try await runPairing(
                    hello: hello,
                    peerCertificateDER: peerCertificateDER,
                    transport: transport,
                    negotiatedProtocol: negotiatedProtocol
                )

            case (.paired(let admittedID), .pair) where admittedID == hello.deviceID:
                guard let attemptID = hello.attemptID,
                      try store.pairingAttempt(id: attemptID) != nil else {
                    throw EkoCoreError.unauthorized
                }
                try await runPairing(
                    hello: hello,
                    peerCertificateDER: peerCertificateDER,
                    transport: transport,
                    negotiatedProtocol: negotiatedProtocol
                )

            case (.revoked(let admittedID), .pair) where admittedID == hello.deviceID:
                // Same-certificate re-pair over a retained revocation receipt. Admission
                // requires explicit local pairing mode or an unexpired persisted attempt,
                // and completion always requires an explicit user confirmation.
                guard let attemptID = hello.attemptID else {
                    throw EkoCoreError.unauthorized
                }
                let resumable = try store.pairingAttempt(id: attemptID) != nil
                guard resumable || pairingMode.acceptsNewPairingAttempts else {
                    throw EkoCoreError.unauthorized
                }
                try await runPairing(
                    hello: hello,
                    peerCertificateDER: peerCertificateDER,
                    transport: transport,
                    negotiatedProtocol: negotiatedProtocol,
                    requiresExplicitUserConfirmation: true
                )

            case (.paired(let admittedID), .unpair) where admittedID == hello.deviceID:
                try store.reserveRestrictedEpoch(
                    deviceID: admittedID,
                    certificateDER: peerCertificateDER,
                    epoch: hello.connectionEpoch
                )
                await displaceAuthoritativeSession(deviceID: admittedID, incomingTransportID: transport.id)
                try await runRestrictedUnpair(hello: hello, transport: transport)

            case (.revoked(let admittedID), .unpair) where admittedID == hello.deviceID:
                try store.reserveRestrictedEpoch(
                    deviceID: admittedID,
                    certificateDER: peerCertificateDER,
                    epoch: hello.connectionEpoch
                )
                await displaceAuthoritativeSession(deviceID: admittedID, incomingTransportID: transport.id)
                try await runRestrictedUnpair(hello: hello, transport: transport)

            case (.revoked(let admittedID), .normal) where admittedID == hello.deviceID:
                try store.reserveRestrictedEpoch(
                    deviceID: admittedID,
                    certificateDER: peerCertificateDER,
                    epoch: hello.connectionEpoch
                )
                await displaceAuthoritativeSession(deviceID: admittedID, incomingTransportID: transport.id)
                try await runRestrictedUnpair(hello: hello, transport: transport)

            default:
                throw EkoCoreError.unauthorized
            }
        } catch {
            await sendError(for: error, transport: transport)
            await transport.close()
            if let claimedDeviceID {
                await sink.connectionStateChanged(deviceID: claimedDeviceID, state: .failed(error.localizedDescription))
                await finishSession(deviceID: claimedDeviceID, transportID: transport.id)
            }
        }
    }

    public func dismiss(deviceID: String, key: String) async throws {
        guard pendingUnpairs[deviceID] == nil, (try? store.pendingUnpair(deviceID: deviceID)) == nil,
              let session = activeSessions[deviceID], session.isLive,
              session.capabilities.contains("dismiss") else {
            throw EkoCoreError.transportClosed
        }
        try await session.transport.send(.dismiss(DismissMessage(key: key)))
    }

    public func requestUnpair(deviceID: String) async throws {
        if let pending = try store.pendingUnpair(deviceID: deviceID) {
            pendingUnpairs[deviceID] = pending.unpairID
            if let session = activeSessions[deviceID] {
                try await session.transport.send(.unpair(pending))
            }
            return
        }
        let unpairID = ProtocolCodec.makeUUIDv4()
        let message = UnpairMessage(
            unpairID: unpairID,
            initiatorID: localIdentity.fingerprint,
            peerID: deviceID,
            reason: .userRequest
        )
        if let session = activeSessions[deviceID] {
            pendingUnpairs[deviceID] = unpairID
            try store.beginUnpair(deviceID: deviceID, message: message, deleteHistory: false)
            try await session.transport.send(.unpair(message))
        } else {
            pendingUnpairs[deviceID] = unpairID
            try store.beginUnpair(deviceID: deviceID, message: message, deleteHistory: true)
        }
    }

    /// Explicit "forget without notifying" user action: closes any live or authoritative
    /// session for the peer and erases all of its local state without a wire exchange.
    public func forgetPeer(deviceID: String) async throws {
        pendingUnpairs.removeValue(forKey: deviceID)
        if let session = activeSessions.removeValue(forKey: deviceID) {
            await session.transport.close()
            await sink.connectionStateChanged(deviceID: deviceID, state: .disconnected)
        }
        try store.forgetWithoutNotifying(deviceID: deviceID)
    }

    /// A newly admitted epoch (restricted unpair admission) immediately ends the authority
    /// of any older live socket: the old connection is removed, notified, and closed, and
    /// its buffered frames are discarded with it.
    private func displaceAuthoritativeSession(deviceID: String, incomingTransportID: UUID) async {
        guard let old = activeSessions[deviceID], old.transport.id != incomingTransportID else { return }
        activeSessions.removeValue(forKey: deviceID)
        try? await old.transport.send(.error(ErrorMessage(code: "superseded")))
        await old.transport.close()
        await sink.connectionStateChanged(deviceID: deviceID, state: .disconnected)
    }

    private func beginNormalSession(
        hello: HelloMessage,
        start: SessionStart,
        transport: any SessionTransport,
        negotiatedProtocol: Int
    ) async throws {
        guard let generation = hello.outboxGeneration else {
            throw EkoCoreError.protocolViolation("normal hello has no outbox generation")
        }
        let old = activeSessions[hello.deviceID]
        let capabilities = localCapabilities.intersection(Set(hello.capabilities))
        activeSessions[hello.deviceID] = ActiveSession(
            transport: transport,
            epoch: hello.connectionEpoch,
            generation: generation,
            capabilities: capabilities,
            isLive: false
        )
        if let old, old.transport.id != transport.id {
            try? await old.transport.send(.error(ErrorMessage(code: "superseded")))
            await old.transport.close()
        }
        await sink.sessionNegotiated(SessionDiagnostics(
            deviceID: hello.deviceID,
            generation: generation,
            protocolVersion: negotiatedProtocol,
            connectionEpoch: hello.connectionEpoch,
            clockSkewMilliseconds: millisecondsSinceEpoch(clock.now()) - hello.phoneTime
        ))
        await sink.connectionStateChanged(deviceID: hello.deviceID, state: .synchronizing)
        try await transport.send(.welcome(WelcomeMessage(
            protocolVersion: negotiatedProtocol,
            deviceID: localIdentity.fingerprint,
            macName: macName,
            outboxGeneration: generation,
            cursor: start.cursor,
            capabilities: capabilities.sorted()
        )))
        try await runNormalLoop(
            hello: hello,
            device: start.device,
            cursor: start.cursor,
            capabilities: capabilities,
            transport: transport
        )
    }

    private func runNormalLoop(
        hello: HelloMessage,
        device: Device,
        cursor: Int64,
        capabilities: Set<String>,
        transport: any SessionTransport
    ) async throws {
        guard let generation = hello.outboxGeneration else {
            throw EkoCoreError.protocolViolation("normal session has no outbox generation")
        }
        var state = SessionStateMachine(
            cursor: cursor,
            generation: generation,
            negotiatedCapabilities: capabilities
        )
        let acknowledgements = AckAccumulator(transport: transport, clock: clock)
        var backlogNotificationCount = 0
        var backlogOTPCount = 0
        var fetchBatches: [[String]] = []

        do {
            while true {
                guard let message = try await receiveWithTimeout(from: transport, duration: .seconds(90)) else { break }
                guard activeSessions[hello.deviceID]?.transport.id == transport.id else {
                    throw EkoCoreError.superseded
                }
                guard let action = try state.accept(message) else { continue }
                switch action {
            case .ingestEvent(let event):
                let outcome = try store.ingestEvent(
                    deviceID: hello.deviceID,
                    generation: generation,
                    event: event
                )
                if !outcome.duplicate {
                    if outcome.replayed, outcome.kind == .posted {
                        backlogNotificationCount += 1
                        if outcome.otpCode != nil, outcome.otpBannerEligible { backlogOTPCount += 1 }
                    }
                    await sink.eventCommitted(outcome)
                    if outcome.kind == .removed, let key = outcome.notificationKey {
                        await sink.notificationRemoved(deviceID: hello.deviceID, key: key)
                    }
                }
                try await acknowledgements.committed(sequence: outcome.sequence)

            case .ingestGap(let gap):
                let committed = try store.ingestGap(
                    deviceID: hello.deviceID,
                    generation: generation,
                    gap: gap
                )
                try await acknowledgements.committed(sequence: committed)

            case .activeProgress:
                break

            case .backlogCompleted(let completion):
                let fetchKeys = try store.reconcileActiveSnapshot(
                    deviceID: hello.deviceID,
                    generation: generation,
                    entries: completion.activeEntries,
                    stateSequence: completion.stateSequence
                )
                try await acknowledgements.flush()
                if !fetchKeys.isEmpty {
                    fetchBatches = stride(from: 0, to: fetchKeys.count, by: ProtocolLimits.maximumFetchKeys).map { start in
                        let end = min(fetchKeys.count, start + ProtocolLimits.maximumFetchKeys)
                        return Array(fetchKeys[start..<end])
                    }
                    if let request = try prepareNextFetch(batches: &fetchBatches, state: &state) {
                        try await transport.send(.fetch(request))
                    }
                }
                if var active = activeSessions[hello.deviceID], active.transport.id == transport.id {
                    active.isLive = true
                    activeSessions[hello.deviceID] = active
                }
                await sink.connectionStateChanged(deviceID: hello.deviceID, state: .online)
                if backlogNotificationCount > 0 {
                    await sink.backlogCompleted(BacklogSummary(
                        deviceID: hello.deviceID,
                        deviceName: device.name,
                        notificationCount: backlogNotificationCount,
                        otpCount: backlogOTPCount
                    ))
                }

            case .applyFetchEvent(let event):
                try store.applyFetchEvent(deviceID: hello.deviceID, generation: generation, event: event)
                if let request = try prepareNextFetch(batches: &fetchBatches, state: &state) {
                    try await transport.send(.fetch(request))
                }

            case .applyFetchMissing(let missing):
                try store.applyFetchMissing(deviceID: hello.deviceID, generation: generation, message: missing)
                if let request = try prepareNextFetch(batches: &fetchBatches, state: &state) {
                    try await transport.send(.fetch(request))
                }

            case .replyPong(let pingID, let phoneTime):
                try await transport.send(.pong(PongMessage(
                    pingID: pingID,
                    phoneTime: phoneTime,
                    macTime: millisecondsSinceEpoch(clock.now())
                )))

            case .ignoreExtension:
                break

            case .unpair(let message):
                guard message.initiatorID == hello.deviceID,
                      message.peerID == localIdentity.fingerprint else {
                    throw EkoCoreError.unauthorized
                }
                let status = try store.applyUnpair(deviceID: hello.deviceID, message: message)
                try await transport.send(.unpairAck(UnpairAckMessage(
                    unpairID: message.unpairID,
                    initiatorID: message.initiatorID,
                    peerID: localIdentity.fingerprint,
                    status: status
                )))
                await transport.close()
                state.close()
                await acknowledgements.cancel()
                await finishSession(deviceID: hello.deviceID, transportID: transport.id)
                return

            case .unpairAcknowledged(let message):
                guard message.initiatorID == localIdentity.fingerprint,
                      message.peerID == hello.deviceID,
                      pendingUnpairs[hello.deviceID] == message.unpairID else {
                    throw EkoCoreError.invalidState("unsolicited unpair acknowledgement")
                }
                pendingUnpairs.removeValue(forKey: hello.deviceID)
                try store.completeUnpair(deviceID: hello.deviceID)
                await transport.close()
                state.close()
                await acknowledgements.cancel()
                await finishSession(deviceID: hello.deviceID, transportID: transport.id)
                return

                case .peerError(let error):
                    if error.fatal {
                        throw EkoCoreError.protocolViolation("peer error: \(error.code)")
                    }
                }
            }
        } catch {
            await acknowledgements.cancel()
            state.close()
            throw error
        }
        await acknowledgements.cancel()
        state.close()
        await finishSession(deviceID: hello.deviceID, transportID: transport.id)
    }

    private func runPairing(
        hello: HelloMessage,
        peerCertificateDER: Data,
        transport: any SessionTransport,
        negotiatedProtocol: Int,
        requiresExplicitUserConfirmation: Bool = false
    ) async throws {
        guard let attemptID = hello.attemptID, let generation = hello.outboxGeneration else {
            throw EkoCoreError.protocolViolation("pair hello is missing attempt metadata")
        }
        let resumed = try store.pairingAttempt(id: attemptID)
        if let resumed {
            guard resumed.deviceID == hello.deviceID,
                  resumed.deviceName == hello.deviceName,
                  resumed.outboxGeneration == generation,
                  EkoCrypto.constantTimeEqual(resumed.peerCertificateDER, peerCertificateDER) else {
                throw EkoCoreError.unauthorized
            }
        }
        let qrPreauthenticated: Bool
        if let resumed {
            qrPreauthenticated = resumed.qrPreauthenticated
        } else if let token = hello.qrToken {
            // Non-consuming validation: the token is burned only when it and the persisted
            // attempt commit atomically below.
            guard pairingMode.redeemableToken(token) else { throw EkoCoreError.unauthorized }
            qrPreauthenticated = true
        } else {
            qrPreauthenticated = false
        }
        let method: PairMethod = qrPreauthenticated ? .qr : .compare
        let pairingMacName = resumed?.localDeviceName ?? macName
        if let resumed, hello.connectionEpoch <= resumed.highestConnectionEpoch {
            throw EkoCoreError.superseded
        }
        try store.reservePairingEpoch(
            deviceID: hello.deviceID,
            certificateDER: peerCertificateDER,
            epoch: hello.connectionEpoch
        )
        let localNonce = resumed?.localNonce ?? (try EkoCrypto.randomBytes(count: 32))
        let localCommitment = try PairingSAS.commitment(
            attemptID: attemptID,
            certificateDER: localIdentity.certificateDER,
            nonce: localNonce
        )
        let expiry = resumed?.expiresAt ?? clock.now().addingTimeInterval(5 * 60)
        let initialAttempt = PersistedPairingAttempt(
            attemptID: attemptID,
            deviceID: hello.deviceID,
            deviceName: hello.deviceName,
            localDeviceName: pairingMacName,
            peerCertificateDER: peerCertificateDER,
            localNonce: localNonce,
            localCommitment: localCommitment,
            peerCommitment: resumed?.peerCommitment ?? Data(),
            peerNonce: resumed?.peerNonce ?? Data(),
            verificationCode: resumed?.verificationCode ?? "",
            transcriptHash: resumed?.transcriptHash ?? Data(),
            qrPreauthenticated: qrPreauthenticated,
            localConfirmed: resumed?.localConfirmed ?? false,
            peerConfirmed: resumed?.peerConfirmed ?? false,
            highestConnectionEpoch: hello.connectionEpoch,
            outboxGeneration: generation,
            initialCursor: resumed?.initialCursor,
            expiresAt: expiry
        )
        if resumed == nil, let token = hello.qrToken {
            try store.consumeQRTokenAndSaveAttempt(token: token, attempt: initialAttempt)
            pairingMode.markTokenConsumed()
        } else {
            try store.savePairingAttempt(initialAttempt)
        }

        guard let requestFrame = try await receivePairingMessage(from: transport, duration: .seconds(10)),
              case .pairRequest(let request) = requestFrame,
              request.attemptID == attemptID,
              request.role == .phone,
              request.method == method,
              request.deviceID == hello.deviceID,
              request.deviceName == hello.deviceName,
              let claimedCertificate = Data(base64Encoded: request.certificateDER),
              EkoCrypto.constantTimeEqual(claimedCertificate, peerCertificateDER) else {
            throw EkoCoreError.protocolViolation("pair_request does not match the authenticated peer")
        }
        try await transport.send(.pairRequest(PairRequestMessage(
            attemptID: attemptID,
            role: .mac,
            method: method,
            deviceID: localIdentity.fingerprint,
            deviceName: pairingMacName,
            certificateDER: localIdentity.certificateDER.base64EncodedString()
        )))

        try await transport.send(.pairCommit(PairCommitMessage(
            attemptID: attemptID,
            deviceID: localIdentity.fingerprint,
            commitment: localCommitment.hexLowercased
        )))

        guard let commitFrame = try await receivePairingMessage(from: transport, duration: .seconds(10)),
              case .pairCommit(let peerCommitMessage) = commitFrame,
              peerCommitMessage.attemptID == attemptID,
              peerCommitMessage.deviceID == hello.deviceID,
              let peerCommitment = Data(hex: peerCommitMessage.commitment), peerCommitment.count == 32 else {
            throw EkoCoreError.protocolViolation("peer pairing commitment is invalid")
        }
        if let resumed, !resumed.peerCommitment.isEmpty,
           !EkoCrypto.constantTimeEqual(resumed.peerCommitment, peerCommitment) {
            throw EkoCoreError.protocolViolation("resumed pairing commitment changed")
        }
        try store.savePairingAttempt(PersistedPairingAttempt(
            attemptID: attemptID,
            deviceID: hello.deviceID,
            deviceName: hello.deviceName,
            localDeviceName: pairingMacName,
            peerCertificateDER: peerCertificateDER,
            localNonce: localNonce,
            localCommitment: localCommitment,
            peerCommitment: peerCommitment,
            peerNonce: resumed?.peerNonce ?? Data(),
            verificationCode: resumed?.verificationCode ?? "",
            transcriptHash: resumed?.transcriptHash ?? Data(),
            qrPreauthenticated: qrPreauthenticated,
            localConfirmed: resumed?.localConfirmed ?? false,
            peerConfirmed: resumed?.peerConfirmed ?? false,
            highestConnectionEpoch: hello.connectionEpoch,
            outboxGeneration: generation,
            initialCursor: resumed?.initialCursor,
            expiresAt: expiry
        ))

        try await transport.send(.pairReveal(PairRevealMessage(
            attemptID: attemptID,
            deviceID: localIdentity.fingerprint,
            nonce: localNonce.hexLowercased
        )))
        guard let revealFrame = try await receivePairingMessage(from: transport, duration: .seconds(10)),
              case .pairReveal(let peerReveal) = revealFrame,
              peerReveal.attemptID == attemptID,
              peerReveal.deviceID == hello.deviceID,
              let peerNonce = Data(hex: peerReveal.nonce), peerNonce.count == 32,
              try PairingSAS.verify(
                commitment: peerCommitment,
                attemptID: attemptID,
                certificateDER: peerCertificateDER,
                revealedNonce: peerNonce
              ) else {
            throw EkoCoreError.protocolViolation("peer pairing reveal does not match its commitment")
        }
        if let resumed, !resumed.peerNonce.isEmpty,
           !EkoCrypto.constantTimeEqual(resumed.peerNonce, peerNonce) {
            throw EkoCoreError.protocolViolation("resumed pairing nonce changed")
        }

        let sas = try PairingSAS.derive(
            attemptID: attemptID,
            firstCertificateDER: localIdentity.certificateDER,
            firstNonce: localNonce,
            secondCertificateDER: peerCertificateDER,
            secondNonce: peerNonce
        )
        var persisted = PersistedPairingAttempt(
            attemptID: attemptID,
            deviceID: hello.deviceID,
            deviceName: hello.deviceName,
            localDeviceName: pairingMacName,
            peerCertificateDER: peerCertificateDER,
            localNonce: localNonce,
            localCommitment: localCommitment,
            peerCommitment: peerCommitment,
            peerNonce: peerNonce,
            verificationCode: sas.verificationCode,
            transcriptHash: sas.transcriptHash,
            qrPreauthenticated: qrPreauthenticated || (resumed?.qrPreauthenticated ?? false),
            localConfirmed: resumed?.localConfirmed ?? false,
            peerConfirmed: resumed?.peerConfirmed ?? false,
            highestConnectionEpoch: hello.connectionEpoch,
            outboxGeneration: generation,
            initialCursor: resumed?.initialCursor,
            expiresAt: expiry
        )
        try store.savePairingAttempt(persisted)

        let pending = PendingPairing(
            attemptID: attemptID,
            deviceID: hello.deviceID,
            deviceName: hello.deviceName,
            verificationCode: sas.verificationCode,
            certificateFingerprint: hello.deviceID,
            qrPreauthenticated: persisted.qrPreauthenticated,
            expiresAt: expiry
        )
        let localConfirmed = persisted.localConfirmed
            || (!requiresExplicitUserConfirmation && persisted.qrPreauthenticated)
            || (await pairingApproval(pending))
        if expiry <= clock.now() {
            try store.deletePairingAttempt(id: attemptID)
            throw EkoCoreError.pairingExpired
        }
        persisted = PersistedPairingAttempt(
            attemptID: persisted.attemptID,
            deviceID: persisted.deviceID,
            deviceName: persisted.deviceName,
            localDeviceName: persisted.localDeviceName,
            peerCertificateDER: persisted.peerCertificateDER,
            localNonce: persisted.localNonce,
            localCommitment: persisted.localCommitment,
            peerCommitment: persisted.peerCommitment,
            peerNonce: persisted.peerNonce,
            verificationCode: persisted.verificationCode,
            transcriptHash: persisted.transcriptHash,
            qrPreauthenticated: persisted.qrPreauthenticated,
            localConfirmed: localConfirmed,
            peerConfirmed: persisted.peerConfirmed,
            highestConnectionEpoch: hello.connectionEpoch,
            outboxGeneration: generation,
            initialCursor: persisted.initialCursor,
            expiresAt: persisted.expiresAt
        )
        try store.savePairingAttempt(persisted)
        try await transport.send(.pairResult(PairResultMessage(
            attemptID: attemptID,
            deviceID: localIdentity.fingerprint,
            transcriptHash: sas.transcriptHash.hexLowercased,
            result: localConfirmed ? .accept : .reject,
            reason: localConfirmed ? nil : .userRejected
        )))
        guard localConfirmed else {
            try store.deletePairingAttempt(id: attemptID)
            throw EkoCoreError.pairingRejected
        }

        guard let resultFrame = try await receivePairingMessage(from: transport, duration: .seconds(30)),
               case .pairResult(let peerResult) = resultFrame,
               peerResult.attemptID == attemptID,
               peerResult.deviceID == hello.deviceID,
               let peerTranscript = Data(hex: peerResult.transcriptHash),
               EkoCrypto.constantTimeEqual(peerTranscript, sas.transcriptHash) else {
            throw EkoCoreError.protocolViolation("peer did not accept the pairing transcript")
        }
        if peerResult.result == .reject {
            guard !persisted.peerConfirmed else {
                throw EkoCoreError.protocolViolation("peer changed accept to reject on retry")
            }
            try store.deletePairingAttempt(id: attemptID)
            throw EkoCoreError.pairingRejected
        }
        guard peerResult.result == .accept else {
            throw EkoCoreError.invalidState("peer sent a pairing phase out of order")
        }

        persisted = PersistedPairingAttempt(
            attemptID: persisted.attemptID,
            deviceID: persisted.deviceID,
            deviceName: persisted.deviceName,
            localDeviceName: persisted.localDeviceName,
            peerCertificateDER: persisted.peerCertificateDER,
            localNonce: persisted.localNonce,
            localCommitment: persisted.localCommitment,
            peerCommitment: persisted.peerCommitment,
            peerNonce: persisted.peerNonce,
            verificationCode: persisted.verificationCode,
            transcriptHash: persisted.transcriptHash,
            qrPreauthenticated: persisted.qrPreauthenticated,
            localConfirmed: true,
            peerConfirmed: true,
            highestConnectionEpoch: hello.connectionEpoch,
            outboxGeneration: generation,
            initialCursor: persisted.initialCursor,
            expiresAt: persisted.expiresAt
        )
        try store.savePairingAttempt(persisted)

        if expiry <= clock.now() {
            try store.deletePairingAttempt(id: attemptID)
            throw EkoCoreError.pairingExpired
        }
        guard let readyFrame = try await receivePairingMessage(from: transport, duration: .seconds(30)),
              case .pairResult(let ready) = readyFrame,
              ready.attemptID == attemptID,
              ready.deviceID == hello.deviceID,
              ready.result == .ready,
              ready.transcriptHash == sas.transcriptHash.hexLowercased,
              ready.outboxGeneration == generation,
              let initialCursor = ready.initialCursor else {
            throw EkoCoreError.protocolViolation("peer did not enter ready pairing state")
        }
        if expiry <= clock.now() {
            try store.deletePairingAttempt(id: attemptID)
            throw EkoCoreError.pairingExpired
        }
        if let priorCursor = persisted.initialCursor, priorCursor != initialCursor {
            throw EkoCoreError.protocolViolation("resumed pairing changed initial_cursor")
        }
        persisted = PersistedPairingAttempt(
            attemptID: persisted.attemptID,
            deviceID: persisted.deviceID,
            deviceName: persisted.deviceName,
            localDeviceName: persisted.localDeviceName,
            peerCertificateDER: persisted.peerCertificateDER,
            localNonce: persisted.localNonce,
            localCommitment: persisted.localCommitment,
            peerCommitment: persisted.peerCommitment,
            peerNonce: persisted.peerNonce,
            verificationCode: persisted.verificationCode,
            transcriptHash: persisted.transcriptHash,
            qrPreauthenticated: persisted.qrPreauthenticated,
            localConfirmed: true,
            peerConfirmed: true,
            highestConnectionEpoch: hello.connectionEpoch,
            outboxGeneration: generation,
            initialCursor: initialCursor,
            expiresAt: persisted.expiresAt
        )
        try store.savePairingAttempt(persisted)

        let device = try store.confirmPairing(
            hello: hello,
            certificateDER: peerCertificateDER,
            initialCursor: initialCursor,
            negotiatedProtocol: negotiatedProtocol,
            endpoint: transport.remoteEndpointDescription
        )
        try await transport.send(.pairResult(PairResultMessage(
            attemptID: attemptID,
            deviceID: localIdentity.fingerprint,
            transcriptHash: sas.transcriptHash.hexLowercased,
            result: .confirmed,
            outboxGeneration: generation,
            initialCursor: initialCursor
        )))
        pairingMode.deactivate()

        let old = activeSessions[hello.deviceID]
        let capabilities = localCapabilities.intersection(Set(hello.capabilities))
        activeSessions[hello.deviceID] = ActiveSession(
            transport: transport,
            epoch: hello.connectionEpoch,
            generation: generation,
            capabilities: capabilities,
            isLive: false
        )
        if let old, old.transport.id != transport.id {
            try? await old.transport.send(.error(ErrorMessage(code: "superseded")))
            await old.transport.close()
        }
        await sink.sessionNegotiated(SessionDiagnostics(
            deviceID: hello.deviceID,
            generation: generation,
            protocolVersion: negotiatedProtocol,
            connectionEpoch: hello.connectionEpoch,
            clockSkewMilliseconds: millisecondsSinceEpoch(clock.now()) - hello.phoneTime
        ))
        try await transport.send(.welcome(WelcomeMessage(
            protocolVersion: negotiatedProtocol,
            deviceID: localIdentity.fingerprint,
            macName: macName,
            outboxGeneration: generation,
            cursor: device.processedThroughSequence,
            capabilities: capabilities.sorted()
        )))
        try await runNormalLoop(
            hello: hello,
            device: device,
            cursor: device.processedThroughSequence,
            capabilities: capabilities,
            transport: transport
        )
    }

    private func runRestrictedUnpair(
        hello: HelloMessage,
        transport: any SessionTransport
    ) async throws {
        if let pending = try store.pendingUnpair(deviceID: hello.deviceID) {
            try await transport.send(.unpair(pending))
            for _ in 0..<2 {
                guard let frame = try await receiveWithTimeout(from: transport, duration: .seconds(10)) else {
                    throw EkoCoreError.transportClosed
                }
                if case .unpairAck(let acknowledgement) = frame,
                   acknowledgement.unpairID == pending.unpairID,
                   acknowledgement.initiatorID == pending.initiatorID,
                   acknowledgement.peerID == hello.deviceID {
                    pendingUnpairs.removeValue(forKey: hello.deviceID)
                    try store.completeUnpair(deviceID: hello.deviceID)
                    await transport.close()
                    return
                }
                if case .unpair(let peerRequest) = frame,
                   hello.unpairID == peerRequest.unpairID,
                   peerRequest.initiatorID == hello.deviceID,
                   peerRequest.peerID == localIdentity.fingerprint {
                    let status = try store.applyUnpair(deviceID: hello.deviceID, message: peerRequest)
                    try await transport.send(.unpairAck(UnpairAckMessage(
                        unpairID: peerRequest.unpairID,
                        initiatorID: peerRequest.initiatorID,
                        peerID: localIdentity.fingerprint,
                        status: status
                    )))
                    continue
                }
                throw EkoCoreError.invalidState("restricted peer sent an unrelated unpair frame")
            }
            throw EkoCoreError.invalidState("restricted peer did not acknowledge unpair")
        }

        if hello.mode == .normal {
            try await transport.send(.error(ErrorMessage(code: "unpaired")))
            await transport.close()
            return
        }

        guard let frame = try await receiveWithTimeout(from: transport, duration: .seconds(10)),
              case .unpair(let unpair) = frame,
              hello.unpairID == unpair.unpairID,
              unpair.initiatorID == hello.deviceID,
              unpair.peerID == localIdentity.fingerprint else {
            throw EkoCoreError.invalidState("revoked peer sent traffic other than unpair")
        }
        let status = try store.applyUnpair(deviceID: hello.deviceID, message: unpair)
        try await transport.send(.unpairAck(UnpairAckMessage(
            unpairID: unpair.unpairID,
            initiatorID: unpair.initiatorID,
            peerID: localIdentity.fingerprint,
            status: status
        )))
        await transport.close()
    }

    private func prepareNextFetch(
        batches: inout [[String]],
        state: inout SessionStateMachine
    ) throws -> FetchMessage? {
        guard !state.hasOutstandingFetch, !batches.isEmpty else { return nil }
        let request = FetchMessage(requestID: ProtocolCodec.makeUUIDv4(), keys: batches.removeFirst())
        try state.beginFetch(request)
        return request
    }

    private func negotiate(_ hello: HelloMessage) throws -> Int {
        guard hello.protoMin <= protocolVersion, hello.protoMax >= protocolVersion else {
            throw EkoCoreError.incompatibleProtocol
        }
        return protocolVersion
    }

    private func receivePairingMessage(
        from transport: any SessionTransport,
        duration: Duration
    ) async throws -> WireMessage? {
        while true {
            guard let message = try await receiveWithTimeout(from: transport, duration: duration) else {
                return nil
            }
            switch message {
            case .ping(let ping):
                try await transport.send(.pong(PongMessage(
                    pingID: ping.pingID,
                    phoneTime: ping.phoneTime,
                    macTime: millisecondsSinceEpoch(clock.now())
                )))
            case .error(let error):
                if error.fatal {
                    throw EkoCoreError.protocolViolation("peer error during pairing: \(error.code)")
                }
            case .pong:
                throw EkoCoreError.invalidState("phone sent pong during pairing")
            default:
                return message
            }
        }
    }

    private func receiveWithTimeout(
        from transport: any SessionTransport,
        duration: Duration
    ) async throws -> WireMessage? {
        let clock = self.clock
        return try await withThrowingTaskGroup(of: WireMessage?.self) { group in
            group.addTask { try await transport.receive() }
            group.addTask {
                try await clock.sleep(for: duration)
                throw EkoCoreError.timedOut
            }
            guard let result = try await group.next() else { throw EkoCoreError.transportClosed }
            group.cancelAll()
            return result
        }
    }

    private func sendError(for error: Error, transport: any SessionTransport) async {
        let code: String
        switch error {
        case EkoCoreError.superseded: code = "superseded"
        case EkoCoreError.incompatibleProtocol: code = "incompatible"
        case EkoCoreError.unauthorized: code = "unauthorized"
        case EkoCoreError.retiredGeneration: code = "stale_generation"
        case EkoCoreError.pairingExpired: code = "pairing_expired"
        case EkoCoreError.pairingRejected: code = "pairing_rejected"
        case EkoCoreError.invalidState(_): code = "invalid_state"
        case EkoCoreError.sequenceConflict: code = "sequence_conflict"
        case EkoCoreError.frameTooLarge: code = "frame_too_large"
        case EkoCoreError.timedOut: code = "protocol_error"
        default: code = "protocol_error"
        }
        try? await transport.send(.error(ErrorMessage(code: code)))
    }

    private func finishSession(deviceID: String, transportID: UUID) async {
        if activeSessions[deviceID]?.transport.id == transportID {
            activeSessions.removeValue(forKey: deviceID)
            await sink.connectionStateChanged(deviceID: deviceID, state: .disconnected)
        }
    }
}

public actor AckAccumulator {
    private let transport: any SessionTransport
    private let clock: any EkoClock
    private var highestCommitted: Int64 = 0
    private var lastSent: Int64 = 0
    private var positionsSinceAck = 0
    private var timer: Task<Void, Never>?
    private var stopped = false

    public init(transport: any SessionTransport, clock: any EkoClock = SystemEkoClock()) {
        self.transport = transport
        self.clock = clock
    }

    public func committed(sequence: Int64) async throws {
        guard !stopped else { return }
        guard sequence >= highestCommitted else {
            throw EkoCoreError.protocolViolation("committed sequence regressed")
        }
        if sequence > highestCommitted {
            highestCommitted = sequence
            positionsSinceAck += 1
        }
        if positionsSinceAck >= 20 {
            try await flush()
        } else if timer == nil, highestCommitted > lastSent {
            let clock = self.clock
            timer = Task { [weak self] in
                try? await clock.sleep(for: .seconds(1))
                try? await self?.flush()
            }
        }
    }

    public func flush() async throws {
        timer?.cancel()
        timer = nil
        guard !stopped, highestCommitted > lastSent else { return }
        let sequence = highestCommitted
        try await transport.send(.ack(AckMessage(sequence: sequence)))
        lastSent = sequence
        positionsSinceAck = 0
    }

    public func cancel() {
        stopped = true
        timer?.cancel()
        timer = nil
    }
}
