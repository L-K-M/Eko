import GRDB
import XCTest
@testable import EkoCore

final class EkoStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_753_351_200)

    func testEventAndCursorCommitTogether() throws {
        let fixture = try makeStore()
        let outcome = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 1)
        )
        XCTAssertFalse(outcome.duplicate)
        XCTAssertEqual(try fixture.store.processedThrough(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!
        ), 1)
        XCTAssertEqual(try fixture.store.notifications().count, 1)
    }

    func testSequenceHoleRollsBackWithoutAdvancingCursor() throws {
        let fixture = try makeStore()
        XCTAssertThrowsError(try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 2)
        ))
        XCTAssertEqual(try fixture.store.processedThrough(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!
        ), 0)
        XCTAssertTrue(try fixture.store.notifications().isEmpty)
    }

    func testExplicitGapAuthorizesFollowingEvent() throws {
        let fixture = try makeStore()
        let gap = BacklogGapMessage(syncID: testSyncID, fromSequence: 1, toSequence: 4, reason: "retention_count")
        XCTAssertEqual(try fixture.store.ingestGap(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            gap: gap
        ), 4)
        _ = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 5)
        )
        XCTAssertEqual(try fixture.store.processedThrough(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!
        ), 5)
        XCTAssertEqual(try fixture.store.gaps().first?.fromSequence, 1)
        XCTAssertEqual(try fixture.store.gaps().first?.toSequence, 4)
    }

    func testDuplicateHasExactlyOnceEffect() throws {
        let fixture = try makeStore()
        let event = testEvent(sequence: 1)
        _ = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: event
        )
        let duplicate = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: event
        )
        XCTAssertTrue(duplicate.duplicate)
        XCTAssertEqual(try fixture.store.notifications().count, 1)
        XCTAssertEqual(try fixture.store.diagnostics().eventCount, 1)
    }

    func testConflictingDuplicateIsRejected() throws {
        let fixture = try makeStore()
        _ = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 1, text: "First body")
        )
        XCTAssertThrowsError(try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 1, text: "Conflicting body")
        ))
    }

    func testSnapshotStateSurvivesUntilFetchAndRejectsStaleResults() throws {
        let fixture = try makeStore()
        let generation = fixture.hello.outboxGeneration!
        _ = try fixture.store.ingestGap(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            gap: BacklogGapMessage(
                syncID: testSyncID,
                fromSequence: 1,
                toSequence: 5,
                reason: "retention_count"
            )
        )
        let entries = [
            ActiveEntry(key: "a", contentHash: String(repeating: "a", count: 64), stateSequence: 5),
            ActiveEntry(key: "b", contentHash: String(repeating: "a", count: 64), stateSequence: 5),
        ]
        XCTAssertEqual(try fixture.store.reconcileActiveSnapshot(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            entries: entries,
            stateSequence: 5
        ), ["a", "b"])
        XCTAssertEqual(try fixture.store.reconcileActiveSnapshot(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            entries: entries,
            stateSequence: 5
        ), ["a", "b"])

        try fixture.store.applyFetchEvent(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            event: testFetchEvent(stateSequence: 5, key: "a")
        )
        XCTAssertThrowsError(try fixture.store.applyFetchMissing(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            message: FetchMissingMessage(
                requestID: "12345678-1234-4abc-8def-1234567890ab",
                key: "b",
                stateSequence: 5
            )
        ))

        _ = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            event: testEvent(
                sequence: 6,
                key: "a",
                text: "Newer body",
                contentHash: String(repeating: "b", count: 64)
            )
        )
        try fixture.store.applyFetchEvent(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            event: testFetchEvent(stateSequence: 5, key: "a", text: "Stale body")
        )
        let current = try XCTUnwrap(fixture.store.notifications().first { $0.key == "a" })
        XCTAssertEqual(current.body, "Newer body")
        XCTAssertEqual(current.lastStateSequence, 6)
    }

    func testOTPDedupeIsDeviceAndCodeScopedButRowsRemainVisible() throws {
        let fixture = try makeStore()
        let first = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 1, key: "child", text: "Code 123456")
        )
        let second = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 2, key: "other", text: "Verification code 123456")
        )
        XCTAssertTrue(first.otpBannerEligible)
        XCTAssertFalse(second.otpBannerEligible)
        XCTAssertEqual(try fixture.store.notifications(query: FeedQuery(codesOnly: true)).count, 2)
        XCTAssertEqual(try fixture.store.diagnostics().otpCount, 2)
    }

    func testBoundedLikeSearchEscapesWildcardInput() throws {
        let fixture = try makeStore()
        _ = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 1, text: "Literal 100%_safe code 778899")
        )
        XCTAssertEqual(try fixture.store.notifications(query: FeedQuery(search: "100%_safe", limit: 10)).count, 1)
        XCTAssertTrue(try fixture.store.notifications(query: FeedQuery(search: "does-not-exist", limit: 10)).isEmpty)
    }

    func testNewGenerationRetiresOldSequenceSpace() throws {
        let fixture = try makeStore()
        let next = testHello(certificateDER: fixture.certificate, generation: testGenerationB, epoch: 2)
        let admission = try fixture.store.beginSession(
            hello: next,
            certificateDER: fixture.certificate,
            negotiatedProtocol: 1,
            endpoint: "127.0.0.1:48808"
        )
        guard case .started(let start) = admission else {
            return XCTFail("Expected the unseen generation to be admitted")
        }
        XCTAssertTrue(start.generationChanged)
        XCTAssertEqual(start.cursor, 0)

        // A retired generation is rejected while the accepted epoch high-water advances.
        let retired = testHello(certificateDER: fixture.certificate, generation: testGenerationA, epoch: 3)
        XCTAssertEqual(try fixture.store.beginSession(
            hello: retired,
            certificateDER: fixture.certificate,
            negotiatedProtocol: 1,
            endpoint: nil
        ), .retiredGeneration)
        XCTAssertEqual(try fixture.store.device(id: fixture.hello.deviceID)?.highestConnectionEpoch, 3)
        XCTAssertEqual(
            try fixture.store.device(id: fixture.hello.deviceID)?.currentGeneration,
            testGenerationB
        )

        // A stale epoch is rejected without touching the high-water, and the next valid
        // epoch is still admitted.
        let zombie = testHello(certificateDER: fixture.certificate, generation: testGenerationB, epoch: 3)
        XCTAssertThrowsError(try fixture.store.beginSession(
            hello: zombie,
            certificateDER: fixture.certificate,
            negotiatedProtocol: 1,
            endpoint: nil
        )) { error in
            XCTAssertEqual(error as? EkoCoreError, .superseded)
        }
        XCTAssertEqual(try fixture.store.device(id: fixture.hello.deviceID)?.highestConnectionEpoch, 3)
        let valid = testHello(certificateDER: fixture.certificate, generation: testGenerationB, epoch: 4)
        guard case .started = try fixture.store.beginSession(
            hello: valid,
            certificateDER: fixture.certificate,
            negotiatedProtocol: 1,
            endpoint: nil
        ) else {
            return XCTFail("Expected a valid newer epoch to be admitted")
        }
        XCTAssertEqual(try fixture.store.device(id: fixture.hello.deviceID)?.highestConnectionEpoch, 4)
    }

    func testAppliedUnpairReceiptIsIdempotentAndRetainsPin() throws {
        let fixture = try makeStore()
        let request = UnpairMessage(
            unpairID: "deadbeef-0000-4000-8000-000000000001",
            initiatorID: fixture.hello.deviceID,
            peerID: String(repeating: "a", count: 64),
            reason: .userRequest
        )
        XCTAssertEqual(try fixture.store.applyUnpair(
            deviceID: fixture.hello.deviceID,
            message: request
        ), .applied)
        XCTAssertEqual(try fixture.store.applyUnpair(
            deviceID: fixture.hello.deviceID,
            message: request
        ), .alreadyApplied)
        XCTAssertEqual(
            try fixture.store.peerAuthorization(for: fixture.certificate),
            .revoked(deviceID: fixture.hello.deviceID)
        )
    }

    func testSameCertificateRePairAfterAppliedReceiptSupersedesAndCleansUp() throws {
        let fixture = try makeStore()
        _ = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 1)
        )
        let request = UnpairMessage(
            unpairID: "deadbeef-0000-4000-8000-000000000010",
            initiatorID: fixture.hello.deviceID,
            peerID: String(repeating: "a", count: 64),
            reason: .userRequest
        )
        XCTAssertEqual(try fixture.store.applyUnpair(
            deviceID: fixture.hello.deviceID,
            message: request
        ), .applied)
        XCTAssertEqual(
            try fixture.store.peerAuthorization(for: fixture.certificate),
            .revoked(deviceID: fixture.hello.deviceID)
        )

        // An explicitly confirmed new pairing with the same certificate supersedes the
        // applied receipt and removes it atomically with the pin commit.
        let repair = testHello(certificateDER: fixture.certificate, generation: testGenerationB, epoch: 9)
        let device = try fixture.store.confirmPairing(
            hello: repair,
            certificateDER: fixture.certificate,
            initialCursor: 42,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        XCTAssertEqual(device.pairingState, .confirmed)
        XCTAssertEqual(device.currentGeneration, testGenerationB)
        XCTAssertEqual(device.processedThroughSequence, 42)
        XCTAssertEqual(
            try fixture.store.peerAuthorization(for: fixture.certificate),
            .paired(deviceID: fixture.hello.deviceID)
        )
        XCTAssertNil(try fixture.store.pendingUnpair(deviceID: fixture.hello.deviceID))

        // The re-paired device resumes normal sync at the confirmed cursor.
        let session = testHello(certificateDER: fixture.certificate, generation: testGenerationB, epoch: 10)
        guard case .started(let start) = try fixture.store.beginSession(
            hello: session,
            certificateDER: fixture.certificate,
            negotiatedProtocol: 1,
            endpoint: nil
        ) else {
            return XCTFail("Expected the re-paired device to admit a normal session")
        }
        XCTAssertEqual(start.cursor, 42)
    }

    func testForgetWithoutNotifyingErasesPeerCompletely() throws {
        let fixture = try makeStore()
        _ = try fixture.store.ingestEvent(
            deviceID: fixture.hello.deviceID,
            generation: fixture.hello.outboxGeneration!,
            event: testEvent(sequence: 1)
        )
        try fixture.store.beginUnpair(
            deviceID: fixture.hello.deviceID,
            message: UnpairMessage(
                unpairID: "deadbeef-0000-4000-8000-000000000011",
                initiatorID: String(repeating: "a", count: 64),
                peerID: fixture.hello.deviceID,
                reason: .userRequest
            ),
            deleteHistory: false
        )
        XCTAssertNotNil(try fixture.store.pendingUnpair(deviceID: fixture.hello.deviceID))

        try fixture.store.forgetWithoutNotifying(deviceID: fixture.hello.deviceID)
        XCTAssertEqual(try fixture.store.peerAuthorization(for: fixture.certificate), .unknown)
        XCTAssertNil(try fixture.store.device(id: fixture.hello.deviceID))
        XCTAssertNil(try fixture.store.pendingUnpair(deviceID: fixture.hello.deviceID))
        XCTAssertEqual(try fixture.store.diagnostics().eventCount, 0)

        // The same certificate can pair from scratch afterwards, and the erased epoch
        // high-water cannot block a fresh attempt.
        XCTAssertNoThrow(try fixture.store.reservePairingEpoch(
            deviceID: fixture.hello.deviceID,
            certificateDER: fixture.certificate,
            epoch: 1
        ))
        let repair = testHello(certificateDER: fixture.certificate, generation: testGenerationB, epoch: 2)
        let device = try fixture.store.confirmPairing(
            hello: repair,
            certificateDER: fixture.certificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        XCTAssertEqual(device.pairingState, .confirmed)
    }

    func testQRTokenConsumptionIsAtomicAndIdempotentPerAttempt() throws {
        let store = try EkoStore(path: temporaryDatabasePath(), clock: FixedClock(date: now))
        let certificate = Data(repeating: 0x42, count: 128)
        let fingerprint = EkoCrypto.fingerprint(of: certificate)
        let token = "single-use-qr-token"
        let attempt = PersistedPairingAttempt(
            attemptID: "00112233445566778899aabbccddeeff",
            deviceID: fingerprint,
            deviceName: "QR Phone",
            localDeviceName: "QR Mac",
            peerCertificateDER: certificate,
            localNonce: Data(repeating: 1, count: 32),
            localCommitment: Data(repeating: 2, count: 32),
            peerCommitment: Data(),
            peerNonce: Data(),
            verificationCode: "",
            transcriptHash: Data(),
            qrPreauthenticated: true,
            localConfirmed: false,
            peerConfirmed: false,
            highestConnectionEpoch: 1,
            outboxGeneration: testGenerationA,
            initialCursor: nil,
            expiresAt: now.addingTimeInterval(300)
        )
        try store.consumeQRTokenAndSaveAttempt(token: token, attempt: attempt)
        XCTAssertEqual(try store.pairingAttempt(id: attempt.attemptID)?.qrPreauthenticated, true)

        // A reconnect after the commit retries the same consumption idempotently.
        XCTAssertNoThrow(try store.consumeQRTokenAndSaveAttempt(token: token, attempt: attempt))

        // A different attempt can never spend the same token.
        let other = PersistedPairingAttempt(
            attemptID: "ffeeddccbbaa99887766554433221100",
            deviceID: fingerprint,
            deviceName: "QR Phone",
            localDeviceName: "QR Mac",
            peerCertificateDER: certificate,
            localNonce: Data(repeating: 3, count: 32),
            localCommitment: Data(repeating: 4, count: 32),
            peerCommitment: Data(),
            peerNonce: Data(),
            verificationCode: "",
            transcriptHash: Data(),
            qrPreauthenticated: true,
            localConfirmed: false,
            peerConfirmed: false,
            highestConnectionEpoch: 2,
            outboxGeneration: testGenerationA,
            initialCursor: nil,
            expiresAt: now.addingTimeInterval(300)
        )
        XCTAssertThrowsError(try store.consumeQRTokenAndSaveAttempt(token: token, attempt: other)) { error in
            XCTAssertEqual(error as? EkoCoreError, .unauthorized)
        }
        XCTAssertNil(try store.pairingAttempt(id: other.attemptID))
    }

    func testActiveSnapshotBeyondLegacyTotalCapIsAccepted() throws {
        let fixture = try makeStore()
        let generation = fixture.hello.outboxGeneration!
        let total = 10_001
        let entries = (0..<total).map {
            ActiveEntry(key: "snapshot-key-\($0)", contentHash: String(repeating: "a", count: 64), stateSequence: 1)
        }
        let fetchKeys = try fixture.store.reconcileActiveSnapshot(
            deviceID: fixture.hello.deviceID,
            generation: generation,
            entries: entries,
            stateSequence: 1
        )
        XCTAssertEqual(fetchKeys.count, total)
        XCTAssertEqual(try fixture.store.notifications().count, 0)
    }

    func testPruneKeepsCurrentGenerationCoverageReceipts() throws {
        let clock = MutableClock(date: now)
        let store = try EkoStore(path: temporaryDatabasePath(), clock: clock)
        let certificate = Data((0..<128).map { UInt8($0 & 0xff) })
        let hello = testHello(certificateDER: certificate)
        _ = try store.confirmPairing(
            hello: hello,
            certificateDER: certificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let generation = hello.outboxGeneration!
        for sequence in Int64(1)...Int64(3) {
            _ = try store.ingestEvent(
                deviceID: hello.deviceID,
                generation: generation,
                event: testEvent(sequence: sequence, key: "key-\(sequence)", text: "body \(sequence)")
            )
        }
        _ = try store.ingestGap(
            deviceID: hello.deviceID,
            generation: generation,
            gap: BacklogGapMessage(syncID: testSyncID, fromSequence: 4, toSequence: 6, reason: "retention_count")
        )
        _ = try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: generation,
            event: testEvent(sequence: 7, key: "key-7")
        )

        clock.date = now.addingTimeInterval(8 * 86_400)
        try store.prune(retentionDays: 7, maximumNotificationsPerDevice: 5_000)

        // Display history prunes, but the cursor never loses its coverage receipts.
        XCTAssertTrue(try store.notifications().isEmpty)
        XCTAssertEqual(try store.processedThrough(deviceID: hello.deviceID, generation: generation), 7)
        XCTAssertEqual(try store.diagnostics().eventCount, 7)
        let receipts = try store.recentEvents(deviceID: hello.deviceID, limit: 20)
        XCTAssertEqual(receipts.count, 7)
        XCTAssertTrue(receipts.allSatisfy { $0.payloadPruned && $0.payloadJSON.isEmpty })
        XCTAssertEqual(try store.gaps().filter { $0.confidence == .definitive }.count, 1)

        // Duplicate redelivery against a stripped receipt stays idempotent.
        let duplicate = try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: generation,
            event: testEvent(sequence: 1, key: "key-1", text: "body 1")
        )
        XCTAssertTrue(duplicate.duplicate)
        // A conflicting redelivery against a receipt is still a fatal sequence conflict.
        XCTAssertThrowsError(try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: generation,
            event: testEvent(sequence: 2, key: "key-2", text: "body 2", contentHash: String(repeating: "f", count: 64))
        )) { error in
            XCTAssertEqual(error as? EkoCoreError, .sequenceConflict)
        }
        // An event over a gap-covered position remains a conflict after pruning.
        XCTAssertThrowsError(try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: generation,
            event: testEvent(sequence: 5, key: "key-5")
        )) { error in
            XCTAssertEqual(error as? EkoCoreError, .sequenceConflict)
        }
    }

    func testPruneDeletesOnlyRetiredGenerationHistory() throws {
        let clock = MutableClock(date: now)
        let store = try EkoStore(path: temporaryDatabasePath(), clock: clock)
        let certificate = Data((0..<128).map { UInt8($0 & 0xff) })
        let hello = testHello(certificateDER: certificate)
        _ = try store.confirmPairing(
            hello: hello,
            certificateDER: certificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let generationA = hello.outboxGeneration!
        _ = try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: generationA,
            event: testEvent(sequence: 1, key: "old-key")
        )
        _ = try store.ingestGap(
            deviceID: hello.deviceID,
            generation: generationA,
            gap: BacklogGapMessage(syncID: testSyncID, fromSequence: 2, toSequence: 3, reason: "retention_age")
        )

        let replacement = testHello(certificateDER: certificate, generation: testGenerationB, epoch: 2)
        guard case .started = try store.beginSession(
            hello: replacement,
            certificateDER: certificate,
            negotiatedProtocol: 1,
            endpoint: nil
        ) else {
            return XCTFail("Expected the new generation to be admitted")
        }
        _ = try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: testGenerationB,
            event: testEvent(sequence: 1, key: "new-key")
        )

        clock.date = now.addingTimeInterval(8 * 86_400)
        try store.prune(retentionDays: 7, maximumNotificationsPerDevice: 5_000)

        // Retired-generation rows are display history and are deleted; the current
        // generation keeps its stripped coverage receipts.
        XCTAssertEqual(try store.diagnostics().eventCount, 1)
        let receipts = try store.recentEvents(deviceID: hello.deviceID, limit: 20)
        XCTAssertEqual(receipts.map(\.generation), [testGenerationB])
        XCTAssertTrue(receipts.allSatisfy { $0.payloadPruned })
        XCTAssertTrue(try store.gaps().isEmpty)
        XCTAssertEqual(try store.processedThrough(deviceID: hello.deviceID, generation: testGenerationB), 1)
        let duplicate = try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: testGenerationB,
            event: testEvent(sequence: 1, key: "new-key")
        )
        XCTAssertTrue(duplicate.duplicate)
    }

    func testForwardMigrationFromInitialSchema() throws {
        let path = try temporaryDatabasePath("migration-\(UUID().uuidString)")
        do {
            let pool = try DatabasePool(path: path)
            let migrator = EkoStore.makeMigrator()
            try migrator.migrate(pool, upTo: EkoStore.migrationIdentifiers[0])
            try migrator.migrate(pool)
            let columns = try pool.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('notification')")
            }
            XCTAssertTrue(columns.contains("body_complete"))
            let hasTombstone = try pool.read { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'unpair_tombstone')"
                ) ?? false
            }
            XCTAssertTrue(hasTombstone)
            let eventColumns = try pool.read { db in
                try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('event')")
            }
            XCTAssertTrue(eventColumns.contains("payload_pruned"))
            let hasConsumedTokens = try pool.read { db in
                try Bool.fetchOne(
                    db,
                    sql: "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'consumed_qr_token')"
                ) ?? false
            }
            XCTAssertTrue(hasConsumedTokens)
        }
        XCTAssertNoThrow(try EkoStore(path: path, clock: FixedClock(date: now)))
    }

    private func makeStore() throws -> (store: EkoStore, hello: HelloMessage, certificate: Data) {
        let path = try temporaryDatabasePath()
        let store = try EkoStore(path: path, clock: FixedClock(date: now))
        let certificate = Data((0..<128).map { UInt8($0 & 0xff) })
        let hello = testHello(certificateDER: certificate)
        _ = try store.confirmPairing(
            hello: hello,
            certificateDER: certificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: "127.0.0.1:48808"
        )
        return (store, hello, certificate)
    }
}
