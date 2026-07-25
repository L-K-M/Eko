import Foundation
import XCTest
@testable import EkoCore

final class SessionManagerTests: XCTestCase {
    private let macCertificate = Data((0..<128).map { UInt8(0x80 ^ UInt8($0 & 0x7f)) })

    // MARK: - Vector-driven supersession

    func testVectorSupersessionStrictEpochOrderingAndDisplacement() async throws {
        let vector = try loadSupersessionVector()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let sink = RecordingSink()
        let manager = makeManager(store: store, identity: mac, sink: sink)

        // Reconstruct the vector's initial state: an authoritative epoch-20 connection.
        guard case .hello(let bootstrap) = vector.normalHello(epoch: vector.higherEpoch - 2, generation: vector.generation) else {
            return XCTFail("normalHello must be a hello")
        }
        _ = try store.confirmPairing(
            hello: bootstrap,
            certificateDER: vector.phoneCertificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let c20 = ScriptedTransport()
        let c20Task = Task { await manager.run(admission: .paired(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: c20) }
        c20.enqueue(vector.normalHello(epoch: vector.equalEpoch, generation: vector.generation))
        enqueueEmptyBacklog(on: c20)
        let condition1 = await waitUntil { sink.hasState(.online, for: vector.phoneID) }

        XCTAssertTrue(condition1)
        XCTAssertTrue(c20.sentMessages().contains { $0.type == "welcome" })

        // equal-epoch-rejected: superseded, c20 stays authoritative.
        let c20b = ScriptedTransport()
        let c20bTask = Task { await manager.run(admission: .paired(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: c20b) }
        c20b.enqueue(vector.equalEpochHello)
        let condition2 = await waitUntil { c20b.isClosed }

        XCTAssertTrue(condition2)
        XCTAssertEqual(c20b.sentErrorCodes(), ["superseded"])
        XCTAssertFalse(c20.isClosed)
        await c20bTask.value

        // lower-epoch-rejected: superseded, c20 stays authoritative.
        let c19 = ScriptedTransport()
        let c19Task = Task { await manager.run(admission: .paired(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: c19) }
        c19.enqueue(vector.normalHello(epoch: vector.lowerEpoch, generation: vector.generation))
        let condition3 = await waitUntil { c19.isClosed }

        XCTAssertTrue(condition3)
        XCTAssertEqual(c19.sentErrorCodes(), ["superseded"])
        XCTAssertFalse(c20.isClosed)
        await c19Task.value

        // higher-epoch-atomically-wins: c21 becomes authoritative, c20 is closed, and a
        // frame buffered on the old connection is discarded unapplied.
        let c21 = ScriptedTransport()
        let c21Task = Task { await manager.run(admission: .paired(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: c21) }
        c21.enqueue(vector.normalHello(epoch: vector.higherEpoch, generation: vector.generation))
        let condition4 = await waitUntil { c20.isClosed && c21.sentMessages().contains { $0.type == "welcome" }}

        XCTAssertTrue(condition4)
        XCTAssertEqual(c20.sentErrorCodes(), ["superseded"])
        c20.enqueue(.event(vector.bufferedEvent))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(try store.diagnostics().eventCount, 0)
        XCTAssertEqual(try store.processedThrough(deviceID: vector.phoneID, generation: vector.generation), 0)
        await c20Task.value

        // epoch-high-water-survives-disconnect: an equal epoch is refused even with no
        // live connection, and the next strictly higher epoch is admitted.
        await c21.close()
        await c21Task.value
        let c21b = ScriptedTransport()
        let c21bTask = Task { await manager.run(admission: .paired(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: c21b) }
        c21b.enqueue(vector.normalHello(epoch: vector.higherEpoch, generation: vector.generation))
        let condition5 = await waitUntil { c21b.isClosed }

        XCTAssertTrue(condition5)
        XCTAssertEqual(c21b.sentErrorCodes(), ["superseded"])
        await c21bTask.value

        let c22 = ScriptedTransport()
        let c22Task = Task { await manager.run(admission: .paired(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: c22) }
        c22.enqueue(vector.normalHello(epoch: vector.higherEpoch + 1, generation: vector.generation))
        let condition6 = await waitUntil { c22.sentMessages().contains { $0.type == "welcome" }}

        XCTAssertTrue(condition6)
        XCTAssertEqual(try store.device(id: vector.phoneID)?.highestConnectionEpoch, vector.higherEpoch + 1)
        await c22.close()
        await c22Task.value
    }

    // MARK: - Vector-driven restricted unpair

    func testVectorOfflineMacTombstoneRestrictsAndDisplacesNormalSession() async throws {
        let vector = try loadUnpairVector()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let sink = RecordingSink()
        let manager = makeManager(store: store, identity: mac, sink: sink)

        guard case .hello(let bootstrap) = vector.normalHello(epoch: 89) else {
            return XCTFail("normalHello must be a hello")
        }
        _ = try store.confirmPairing(
            hello: bootstrap,
            certificateDER: vector.phoneCertificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let live = ScriptedTransport()
        let liveTask = Task { await manager.run(admission: .paired(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: live) }
        live.enqueue(vector.normalHello(epoch: 90))
        enqueueEmptyBacklog(on: live)
        let condition7 = await waitUntil { sink.hasState(.online, for: vector.phoneID) }

        XCTAssertTrue(condition7)

        // Offline local unpair: the Mac deletes its normal data and keeps the tombstone.
        let tombstone = UnpairMessage(
            unpairID: vector.macInitiatedUnpairID,
            initiatorID: mac.fingerprint,
            peerID: vector.phoneID,
            reason: .userRequest
        )
        try store.beginUnpair(deviceID: vector.phoneID, message: tombstone, deleteHistory: true)

        // The unaware phone reconnects in normal mode with a strictly newer epoch: it is
        // forced into restricted unpair, no welcome is sent, and the old live socket is
        // displaced immediately.
        let unaware = ScriptedTransport()
        let unawareTask = Task { await manager.run(admission: .revoked(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: unaware) }
        unaware.enqueue(vector.unawareNormalHello)
        let condition8 = await waitUntil {
            live.isClosed && unaware.sentMessages().contains { $0.type == "unpair" }
        }
        XCTAssertTrue(condition8)
        XCTAssertEqual(live.sentErrorCodes(), ["superseded"])
        XCTAssertFalse(unaware.sentMessages().contains { $0.type == "welcome" })
        guard case .unpair(let sentUnpair) = unaware.sentMessages().first(where: { $0.type == "unpair" }) else {
            return XCTFail("Expected the stored unpair to be sent")
        }
        XCTAssertEqual(sentUnpair.unpairID, vector.macInitiatedUnpairID)
        XCTAssertEqual(sentUnpair.initiatorID, mac.fingerprint)
        XCTAssertEqual(sentUnpair.peerID, vector.phoneID)

        unaware.enqueue(.unpairAck(UnpairAckMessage(
            unpairID: vector.macInitiatedUnpairID,
            initiatorID: mac.fingerprint,
            peerID: vector.phoneID,
            status: .applied
        )))
        let condition9 = await waitUntil { unaware.isClosed }

        XCTAssertTrue(condition9)
        await unawareTask.value
        await liveTask.value
        XCTAssertNil(try store.device(id: vector.phoneID))
        XCTAssertNil(try store.pendingUnpair(deviceID: vector.phoneID))
        XCTAssertEqual(try store.peerAuthorization(for: vector.phoneCertificate), .unknown)
    }

    func testVectorLostAckReusesSameUnpairIDAndAppliedReceipt() async throws {
        let vector = try loadUnpairVector()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let manager = makeManager(store: store, identity: mac, sink: RecordingSink())

        guard case .hello(let bootstrap) = vector.normalHello(epoch: 69) else {
            return XCTFail("normalHello must be a hello")
        }
        _ = try store.confirmPairing(
            hello: bootstrap,
            certificateDER: vector.phoneCertificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let tombstone = UnpairMessage(
            unpairID: vector.lostAckUnpairID,
            initiatorID: mac.fingerprint,
            peerID: vector.phoneID,
            reason: .userRequest
        )
        try store.beginUnpair(deviceID: vector.phoneID, message: tombstone, deleteHistory: true)

        // The phone dials unpair-only with the same unpair_id and delivers the previously
        // lost acknowledgement as already_applied.
        let transport = ScriptedTransport()
        let task = Task { await manager.run(admission: .revoked(deviceID: vector.phoneID), peerCertificateDER: vector.phoneCertificate, transport: transport) }
        transport.enqueue(vector.lostAckHello)
        let condition10 = await waitUntil { transport.sentMessages().contains { $0.type == "unpair" }}

        XCTAssertTrue(condition10)
        XCTAssertFalse(transport.sentMessages().contains { $0.type == "welcome" })
        transport.enqueue(.unpairAck(UnpairAckMessage(
            unpairID: vector.lostAckUnpairID,
            initiatorID: mac.fingerprint,
            peerID: vector.phoneID,
            status: .alreadyApplied
        )))
        let condition11 = await waitUntil { transport.isClosed }

        XCTAssertTrue(condition11)
        await task.value
        XCTAssertNil(try store.device(id: vector.phoneID))
    }

    // MARK: - Same-certificate re-pair after an applied receipt

    func testRePairOverAppliedReceiptRequiresExplicitConfirmationAndCleansReceipt() async throws {
        let phone = try vectorPhoneCertificate()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let pairingMode = PairingModeController()
        let approval = ApprovalRecorder(verdict: true)
        let manager = makeManager(store: store, identity: mac, sink: RecordingSink(), pairingMode: pairingMode) { pending in
            approval.request(pending)
        }

        let initial = testHello(certificateDER: phone.der, epoch: 1)
        _ = try store.confirmPairing(
            hello: initial,
            certificateDER: phone.der,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let receipt = UnpairMessage(
            unpairID: "deadbeef-0000-4000-8000-000000000020",
            initiatorID: phone.deviceID,
            peerID: mac.fingerprint,
            reason: .userRequest
        )
        XCTAssertEqual(try store.applyUnpair(deviceID: phone.deviceID, message: receipt), .applied)

        let invitation = try pairingMode.activate()
        let attemptID = "00112233445566778899aabbccddeeff"
        let transport = ScriptedTransport()
        let task = Task { await manager.run(admission: .revoked(deviceID: phone.deviceID), peerCertificateDER: phone.der, transport: transport) }
        let phoneNonce = Data((0..<32).map { UInt8($0) })
        let phoneCommitment = try PairingSAS.commitment(attemptID: attemptID, certificateDER: phone.der, nonce: phoneNonce)
        transport.enqueue(testPairHello(certificateDER: phone.der, attemptID: attemptID, epoch: 2, qrToken: invitation.token))
        transport.enqueue(.pairRequest(PairRequestMessage(
            attemptID: attemptID,
            role: .phone,
            method: .qr,
            deviceID: phone.deviceID,
            deviceName: "Vector Phone",
            certificateDER: phone.der.base64EncodedString()
        )))
        transport.enqueue(.pairCommit(PairCommitMessage(
            attemptID: attemptID,
            deviceID: phone.deviceID,
            commitment: phoneCommitment.hexLowercased
        )))

        let condition12 = await waitUntil {
            !transport.sentMessages().compactMap { message -> PairRevealMessage? in
                guard case .pairReveal(let reveal) = message, reveal.deviceID == mac.fingerprint else { return nil }
                return reveal
            }.isEmpty
        }

        XCTAssertTrue(condition12)
        let macReveal = try XCTUnwrap(transport.sentMessages().compactMap { message -> PairRevealMessage? in
            guard case .pairReveal(let reveal) = message, reveal.deviceID == mac.fingerprint else { return nil }
            return reveal
        }.first)
        let macNonce = try XCTUnwrap(Data(hex: macReveal.nonce))
        let sas = try PairingSAS.derive(
            attemptID: attemptID,
            firstCertificateDER: mac.certificateDER,
            firstNonce: macNonce,
            secondCertificateDER: phone.der,
            secondNonce: phoneNonce
        )
        transport.enqueue(.pairReveal(PairRevealMessage(
            attemptID: attemptID,
            deviceID: phone.deviceID,
            nonce: phoneNonce.hexLowercased
        )))

        // The QR token authenticates the method, but re-pairing over a revocation receipt
        // still requires the explicit user confirmation.
        let condition13 = await waitUntil { approval.callCount == 1 }

        XCTAssertTrue(condition13)
        XCTAssertEqual(approval.pending.first?.attemptID, attemptID)
        XCTAssertEqual(approval.pending.first?.qrPreauthenticated, true)

        let condition14 = await waitUntil {
            transport.sentMessages().contains { message in
                guard case .pairResult(let result) = message else { return false }
                return result.result == .accept
            }
        }
        XCTAssertTrue(condition14)
        transport.enqueue(.pairResult(PairResultMessage(
            attemptID: attemptID,
            deviceID: phone.deviceID,
            transcriptHash: sas.transcriptHash.hexLowercased,
            result: .accept
        )))
        transport.enqueue(.pairResult(PairResultMessage(
            attemptID: attemptID,
            deviceID: phone.deviceID,
            transcriptHash: sas.transcriptHash.hexLowercased,
            result: .ready,
            outboxGeneration: testGenerationA,
            initialCursor: 7
        )))
        let condition15 = await waitUntil {
            transport.sentMessages().contains { $0.type == "welcome" }
        }
        XCTAssertTrue(condition15)

        let device = try XCTUnwrap(try store.device(id: phone.deviceID))
        XCTAssertEqual(device.pairingState, .confirmed)
        XCTAssertEqual(device.processedThroughSequence, 7)
        XCTAssertNil(try store.pendingUnpair(deviceID: phone.deviceID))
        XCTAssertEqual(try store.peerAuthorization(for: phone.der), .paired(deviceID: phone.deviceID))
        guard case .pairRequest(let macRequest) = transport.sentMessages().first(where: { $0.type == "pair_request" }) else {
            return XCTFail("Expected the Mac pair_request")
        }
        XCTAssertEqual(macRequest.method, .qr)

        await transport.close()
        await task.value
    }

    func testRePairOverAppliedReceiptKeepsReceiptWhenUserRejects() async throws {
        let phone = try vectorPhoneCertificate()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let pairingMode = PairingModeController()
        let approval = ApprovalRecorder(verdict: false)
        let manager = makeManager(store: store, identity: mac, sink: RecordingSink(), pairingMode: pairingMode) { pending in
            approval.request(pending)
        }

        let initial = testHello(certificateDER: phone.der, epoch: 1)
        _ = try store.confirmPairing(
            hello: initial,
            certificateDER: phone.der,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let receipt = UnpairMessage(
            unpairID: "deadbeef-0000-4000-8000-000000000021",
            initiatorID: phone.deviceID,
            peerID: mac.fingerprint,
            reason: .userRequest
        )
        XCTAssertEqual(try store.applyUnpair(deviceID: phone.deviceID, message: receipt), .applied)

        let invitation = try pairingMode.activate()
        let attemptID = "11002233445566778899aabbccddeeff"
        let transport = ScriptedTransport()
        let task = Task { await manager.run(admission: .revoked(deviceID: phone.deviceID), peerCertificateDER: phone.der, transport: transport) }
        transport.enqueue(testPairHello(certificateDER: phone.der, attemptID: attemptID, epoch: 2, qrToken: invitation.token))
        transport.enqueue(.pairRequest(PairRequestMessage(
            attemptID: attemptID,
            role: .phone,
            method: .qr,
            deviceID: phone.deviceID,
            deviceName: "Vector Phone",
            certificateDER: phone.der.base64EncodedString()
        )))
        let phoneNonce = Data((0..<32).map { UInt8(255 &- $0) })
        let phoneCommitment = try PairingSAS.commitment(attemptID: attemptID, certificateDER: phone.der, nonce: phoneNonce)
        transport.enqueue(.pairCommit(PairCommitMessage(
            attemptID: attemptID,
            deviceID: phone.deviceID,
            commitment: phoneCommitment.hexLowercased
        )))
        let condition16 = await waitUntil {
            transport.sentMessages().contains { message in
                guard case .pairReveal(let reveal) = message else { return false }
                return reveal.deviceID == mac.fingerprint
            }
        }
        XCTAssertTrue(condition16)
        transport.enqueue(.pairReveal(PairRevealMessage(
            attemptID: attemptID,
            deviceID: phone.deviceID,
            nonce: phoneNonce.hexLowercased
        )))
        let condition17 = await waitUntil { transport.isClosed }

        XCTAssertTrue(condition17)
        XCTAssertEqual(approval.callCount, 1)
        XCTAssertTrue(transport.sentMessages().contains { message in
            guard case .pairResult(let result) = message else { return false }
            return result.result == .reject
        })
        XCTAssertEqual(transport.sentErrorCodes(), ["pairing_rejected"])
        await task.value

        // The receipt survives the rejected re-pair: the peer stays revoked and can only
        // run the restricted exchange or be forgotten explicitly.
        XCTAssertEqual(try store.device(id: phone.deviceID)?.pairingState, .revokedPending)
        XCTAssertEqual(try store.peerAuthorization(for: phone.der), .revoked(deviceID: phone.deviceID))
    }

    func testRePairOverAppliedReceiptNeedsPairingModeOrPersistedAttempt() async throws {
        let phone = try vectorPhoneCertificate()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let manager = makeManager(store: store, identity: mac, sink: RecordingSink())

        let initial = testHello(certificateDER: phone.der, epoch: 1)
        _ = try store.confirmPairing(
            hello: initial,
            certificateDER: phone.der,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let receipt = UnpairMessage(
            unpairID: "deadbeef-0000-4000-8000-000000000022",
            initiatorID: phone.deviceID,
            peerID: mac.fingerprint,
            reason: .userRequest
        )
        XCTAssertEqual(try store.applyUnpair(deviceID: phone.deviceID, message: receipt), .applied)

        // No pairing mode and no persisted attempt: the pair hello is refused.
        let transport = ScriptedTransport()
        let task = Task { await manager.run(admission: .revoked(deviceID: phone.deviceID), peerCertificateDER: phone.der, transport: transport) }
        transport.enqueue(testPairHello(certificateDER: phone.der, attemptID: "22002233445566778899aabbccddeeff", epoch: 2, qrToken: nil))
        let condition18 = await waitUntil { transport.isClosed }

        XCTAssertTrue(condition18)
        XCTAssertEqual(transport.sentErrorCodes(), ["unauthorized"])
        await task.value
        XCTAssertEqual(try store.peerAuthorization(for: phone.der), .revoked(deviceID: phone.deviceID))
    }

    // MARK: - QR token consumption

    func testQRTokenSurvivesFailuresBeforePersistenceAndResumeAfterCommit() async throws {
        let phone = try vectorPhoneCertificate()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let pairingMode = PairingModeController()
        let approval = ApprovalRecorder(verdict: true)
        let manager = makeManager(store: store, identity: mac, sink: RecordingSink(), pairingMode: pairingMode) { pending in
            approval.request(pending)
        }
        try store.reservePairingEpoch(deviceID: phone.deviceID, certificateDER: phone.der, epoch: 5)
        let invitation = try pairingMode.activate()
        let attemptID = "33002233445566778899aabbccddeeff"
        _ = pairingMode.admitUnknown(certificateDER: phone.der)

        // A stale-epoch attempt fails before persistence: the token must not be burned.
        let stale = ScriptedTransport()
        let staleTask = Task { await manager.run(admission: .pairing(fingerprint: phone.deviceID), peerCertificateDER: phone.der, transport: stale) }
        stale.enqueue(testPairHello(certificateDER: phone.der, attemptID: attemptID, epoch: 3, qrToken: invitation.token))
        let condition19 = await waitUntil { stale.isClosed }

        XCTAssertTrue(condition19)
        XCTAssertEqual(stale.sentErrorCodes(), ["superseded"])
        await staleTask.value
        XCTAssertNil(try store.pairingAttempt(id: attemptID))
        XCTAssertTrue(pairingMode.redeemableToken(invitation.token))

        // A disconnect after the hello but before pair_request commits the consumption and
        // the attempt atomically; the retry resumes without re-validating the token.
        let dropped = ScriptedTransport()
        let droppedTask = Task { await manager.run(admission: .pairing(fingerprint: phone.deviceID), peerCertificateDER: phone.der, transport: dropped) }
        dropped.enqueue(testPairHello(certificateDER: phone.der, attemptID: attemptID, epoch: 6, qrToken: invitation.token))
        let condition20 = await waitUntil { (try? store.pairingAttempt(id: attemptID)) != nil }

        XCTAssertTrue(condition20)
        await dropped.close()
        await droppedTask.value
        XCTAssertEqual(try store.pairingAttempt(id: attemptID)?.qrPreauthenticated, true)
        XCTAssertFalse(pairingMode.redeemableToken(invitation.token))

        let resumed = ScriptedTransport()
        let resumedTask = Task { await manager.run(admission: .pairing(fingerprint: phone.deviceID), peerCertificateDER: phone.der, transport: resumed) }
        resumed.enqueue(testPairHello(certificateDER: phone.der, attemptID: attemptID, epoch: 7, qrToken: invitation.token))
        resumed.enqueue(.pairRequest(PairRequestMessage(
            attemptID: attemptID,
            role: .phone,
            method: .qr,
            deviceID: phone.deviceID,
            deviceName: "Vector Phone",
            certificateDER: phone.der.base64EncodedString()
        )))
        let condition21 = await waitUntil {
            resumed.sentMessages().contains { message in
                guard case .pairCommit(let commit) = message else { return false }
                return commit.deviceID == mac.fingerprint
            }
        }
        XCTAssertTrue(condition21)
        await resumed.close()
        await resumedTask.value
    }

    // MARK: - Forget without notifying

    func testForgetPeerClosesLiveSessionAndErasesState() async throws {
        let phone = try vectorPhoneCertificate()
        let store = try EkoStore(path: temporaryDatabasePath())
        let mac = StubIdentity(certificateDER: macCertificate)
        let sink = RecordingSink()
        let manager = makeManager(store: store, identity: mac, sink: sink)

        let initial = testHello(certificateDER: phone.der, epoch: 1)
        _ = try store.confirmPairing(
            hello: initial,
            certificateDER: phone.der,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let live = ScriptedTransport()
        let liveTask = Task { await manager.run(admission: .paired(deviceID: phone.deviceID), peerCertificateDER: phone.der, transport: live) }
        live.enqueue(testHello(certificateDER: phone.der, epoch: 2))
        enqueueEmptyBacklog(on: live)
        let condition22 = await waitUntil { sink.hasState(.online, for: phone.deviceID) }

        XCTAssertTrue(condition22)

        try await manager.forgetPeer(deviceID: phone.deviceID)
        XCTAssertTrue(live.isClosed)
        await liveTask.value
        XCTAssertNil(try store.device(id: phone.deviceID))
        XCTAssertEqual(try store.peerAuthorization(for: phone.der), .unknown)
        do {
            _ = try await manager.dismiss(deviceID: phone.deviceID, key: "any")
            XCTFail("dismiss must fail for a forgotten peer")
        } catch {}
    }

    // MARK: - Helpers

    private func makeManager(
        store: EkoStore,
        identity: StubIdentity,
        sink: RecordingSink,
        pairingMode: PairingModeController = PairingModeController(),
        approval: @escaping SessionManager.PairingApproval = { _ in false }
    ) -> SessionManager {
        SessionManager(
            store: store,
            localIdentity: identity,
            macName: "Vector Mac",
            pairingMode: pairingMode,
            sink: sink,
            pairingApproval: approval
        )
    }

    private func enqueueEmptyBacklog(on transport: ScriptedTransport) {
        transport.enqueue(.backlogStart(BacklogStartMessage(
            syncID: testSyncID,
            fromSequence: 1,
            replayToSequence: 0,
            eventCount: 0
        )))
        transport.enqueue(.activeChunk(ActiveChunkMessage(
            syncID: testSyncID,
            index: 0,
            final: true,
            active: []
        )))
        transport.enqueue(.backlogEnd(BacklogEndMessage(syncID: testSyncID, stateSequence: 0)))
    }

    private func testPairHello(certificateDER: Data, attemptID: String, epoch: Int64, qrToken: String?) -> WireMessage {
        .hello(HelloMessage(
            mode: .pair,
            protoMin: 1,
            protoMax: 1,
            deviceID: EkoCrypto.fingerprint(of: certificateDER),
            deviceName: "Vector Phone",
            os: "android",
            osVersion: 36,
            capabilities: ["notif", "dismiss", "otp_context"],
            outboxGeneration: testGenerationA,
            connectionEpoch: epoch,
            phoneTime: 1_753_351_700_000,
            attemptID: attemptID,
            qrToken: qrToken
        ))
    }

    private func waitUntil(
        timeout: TimeInterval = 5,
        condition: @Sendable () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

// MARK: - Test doubles

private struct StubIdentity: SessionLocalIdentity {
    let certificateDER: Data
    let fingerprint: String

    init(certificateDER: Data) {
        self.certificateDER = certificateDER
        self.fingerprint = EkoCrypto.fingerprint(of: certificateDER)
    }
}

private final class ScriptedTransport: SessionTransport, @unchecked Sendable {
    let id = UUID()
    let remoteEndpointDescription = "scripted"
    private let lock = NSLock()
    private var inbox: [WireMessage] = []
    private var closedFlag = false
    private var waiter: CheckedContinuation<WireMessage?, Never>?
    private var sentStorage: [WireMessage] = []

    func receive() async throws -> WireMessage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if !inbox.isEmpty {
                let message = inbox.removeFirst()
                lock.unlock()
                continuation.resume(returning: message)
                return
            }
            if closedFlag {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }

    func send(_ message: WireMessage) async throws {
        lock.lock()
        sentStorage.append(message)
        lock.unlock()
    }

    func close() async {
        lock.lock()
        closedFlag = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(returning: nil)
    }

    func enqueue(_ message: WireMessage) {
        lock.lock()
        if let pending = waiter, inbox.isEmpty, !closedFlag {
            waiter = nil
            lock.unlock()
            pending.resume(returning: message)
            return
        }
        inbox.append(message)
        lock.unlock()
    }

    func sentMessages() -> [WireMessage] {
        lock.lock()
        defer { lock.unlock() }
        return sentStorage
    }

    func sentErrorCodes() -> [String] {
        sentMessages().compactMap { message in
            guard case .error(let error) = message else { return nil }
            return error.code
        }
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closedFlag
    }
}

private final class RecordingSink: SessionEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var states: [(deviceID: String, state: DeviceConnectionState)] = []

    func connectionStateChanged(deviceID: String, state: DeviceConnectionState) async {
        lock.lock()
        states.append((deviceID, state))
        lock.unlock()
    }

    func sessionNegotiated(_ diagnostics: SessionDiagnostics) async {}
    func eventCommitted(_ outcome: IngestOutcome) async {}
    func backlogCompleted(_ summary: BacklogSummary) async {}
    func notificationRemoved(deviceID: String, key: String) async {}

    func hasState(_ state: DeviceConnectionState, for deviceID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states.contains { $0.deviceID == deviceID && $0.state == state }
    }
}

private final class ApprovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let verdict: Bool
    private(set) var pending: [PendingPairing] = []

    init(verdict: Bool) {
        self.verdict = verdict
    }

    func request(_ pairing: PendingPairing) -> Bool {
        lock.lock()
        pending.append(pairing)
        lock.unlock()
        return verdict
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }
}

// MARK: - Vector loading

private struct SupersessionVector {
    let phoneCertificate: Data
    let phoneID: String
    let generation: String
    let equalEpoch: Int64
    let lowerEpoch: Int64
    let higherEpoch: Int64
    let equalEpochHello: WireMessage
    let bufferedEvent: EventMessage

    func normalHello(epoch: Int64, generation: String) -> WireMessage {
        .hello(HelloMessage(
            mode: .normal,
            protoMin: 1,
            protoMax: 1,
            deviceID: phoneID,
            deviceName: "Vector Phone",
            os: "android",
            osVersion: 36,
            capabilities: ["notif", "dismiss", "otp_context"],
            outboxGeneration: generation,
            connectionEpoch: epoch,
            phoneTime: 1_753_351_500_000
        ))
    }
}

private struct UnpairVector {
    let phoneCertificate: Data
    let phoneID: String
    let generation: String
    let macInitiatedUnpairID: String
    let lostAckUnpairID: String
    let unawareNormalHello: WireMessage
    let lostAckHello: WireMessage

    func normalHello(epoch: Int64) -> WireMessage {
        .hello(HelloMessage(
            mode: .normal,
            protoMin: 1,
            protoMax: 1,
            deviceID: phoneID,
            deviceName: "Vector Phone",
            os: "android",
            osVersion: 36,
            capabilities: ["notif", "dismiss", "otp_context"],
            outboxGeneration: generation,
            connectionEpoch: epoch,
            phoneTime: 1_753_351_620_000
        ))
    }
}

private func vectorPhoneCertificate() throws -> (der: Data, deviceID: String) {
    let data = try Data(contentsOf: protocolVectorURL("scenarios/pairing-retry.json"))
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let steps = try XCTUnwrap(root["steps"] as? [[String: Any]])
    for step in steps {
        guard let frame = step["frame"] as? [String: Any],
              frame["type"] as? String == "pair_request",
              frame["role"] as? String == "phone",
              let encoded = frame["cert_der"] as? String,
              let der = Data(base64Encoded: encoded) else { continue }
        return (der, EkoCrypto.fingerprint(of: der))
    }
    throw EkoCoreError.invalidData("pairing vector has no phone certificate")
}

private func decodeVectorMessage(_ frame: [String: Any]) throws -> WireMessage {
    let payload = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
    return try ProtocolCodec.decode(payload)
}

private func loadSupersessionVector() throws -> SupersessionVector {
    let phone = try vectorPhoneCertificate()
    let data = try Data(contentsOf: protocolVectorURL("scenarios/supersession.json"))
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let initial = try XCTUnwrap(root["initial"] as? [String: Any])
    let generation = try XCTUnwrap(initial["generation"] as? String)
    let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])
    func caseFrame(_ id: String) throws -> [String: Any] {
        let entry = try XCTUnwrap(cases.first { $0["id"] as? String == id })
        return try XCTUnwrap(entry["receive"] as? [String: Any])
    }
    guard case .hello(let equalHello) = try decodeVectorMessage(caseFrame("equal-epoch-rejected")) else {
        throw EkoCoreError.invalidData("equal-epoch vector hello is invalid")
    }
    XCTAssertEqual(equalHello.deviceID, phone.deviceID)
    guard case .hello(let lowerHello) = try decodeVectorMessage(caseFrame("lower-epoch-rejected")) else {
        throw EkoCoreError.invalidData("lower-epoch vector hello is invalid")
    }
    guard case .hello(let higherHello) = try decodeVectorMessage(caseFrame("higher-epoch-atomically-wins")) else {
        throw EkoCoreError.invalidData("higher-epoch vector hello is invalid")
    }
    let winningCase = try XCTUnwrap(cases.first { $0["id"] as? String == "higher-epoch-atomically-wins" })
    let bufferedFrame = try XCTUnwrap(winningCase["buffered_old_connection_frame"] as? [String: Any])
    guard case .event(let bufferedEvent) = try decodeVectorMessage(bufferedFrame) else {
        throw EkoCoreError.invalidData("buffered vector event is invalid")
    }
    return SupersessionVector(
        phoneCertificate: phone.der,
        phoneID: phone.deviceID,
        generation: generation,
        equalEpoch: equalHello.connectionEpoch,
        lowerEpoch: lowerHello.connectionEpoch,
        higherEpoch: higherHello.connectionEpoch,
        equalEpochHello: .hello(equalHello),
        bufferedEvent: bufferedEvent
    )
}

private func loadUnpairVector() throws -> UnpairVector {
    let phone = try vectorPhoneCertificate()
    let data = try Data(contentsOf: protocolVectorURL("scenarios/unpair.json"))
    let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let cases = try XCTUnwrap(root["cases"] as? [[String: Any]])

    let offlineMac = try XCTUnwrap(cases.first { $0["id"] as? String == "offline-mac-tombstone-restricts-unaware-normal-phone" })
    let offlineSteps = try XCTUnwrap(offlineMac["steps"] as? [[String: Any]])
    let normalHelloFrame = try XCTUnwrap(offlineSteps.compactMap { $0["frame"] as? [String: Any] }.first { $0["type"] as? String == "hello" })
    guard case .hello(let unawareHello) = try decodeVectorMessage(normalHelloFrame) else {
        throw EkoCoreError.invalidData("unaware vector hello is invalid")
    }
    XCTAssertEqual(unawareHello.deviceID, phone.deviceID)
    let generation = try XCTUnwrap(unawareHello.outboxGeneration)
    let macUnpairFrame = try XCTUnwrap(offlineSteps.compactMap { $0["frame"] as? [String: Any] }.first {
        $0["type"] as? String == "unpair" && $0["initiator_id"] as? String != phone.deviceID
    })
    let macUnpairID = try XCTUnwrap(macUnpairFrame["unpair_id"] as? String)

    let lostAck = try XCTUnwrap(cases.first { $0["id"] as? String == "lost-ack-reuses-id-and-receipt" })
    let lostSteps = try XCTUnwrap(lostAck["steps"] as? [[String: Any]])
    let lostHelloFrame = try XCTUnwrap(lostSteps.compactMap { $0["frame"] as? [String: Any] }.first { $0["type"] as? String == "hello" })
    guard case .hello(let lostAckHello) = try decodeVectorMessage(lostHelloFrame) else {
        throw EkoCoreError.invalidData("lost-ack vector hello is invalid")
    }
    let lostAckUnpairID = try XCTUnwrap(lostAckHello.unpairID)

    return UnpairVector(
        phoneCertificate: phone.der,
        phoneID: phone.deviceID,
        generation: generation,
        macInitiatedUnpairID: macUnpairID,
        lostAckUnpairID: lostAckUnpairID,
        unawareNormalHello: .hello(unawareHello),
        lostAckHello: .hello(lostAckHello)
    )
}
