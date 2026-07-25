import XCTest
@testable import EkoCore

final class PeerAdmissionTests: XCTestCase {
    func testKnownPeerRequiresItsExactStoredDER() throws {
        let path = try temporaryDatabasePath()
        let store = try EkoStore(path: path)
        let certificate = Data(repeating: 0x44, count: 128)
        let hello = testHello(certificateDER: certificate)
        _ = try store.confirmPairing(
            hello: hello,
            certificateDER: certificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        let pairingMode = PairingModeController()
        let authorizer = StorePeerAuthorizer(store: store, pairingMode: pairingMode)
        XCTAssertEqual(authorizer.authorize(certificateDER: certificate), .paired(deviceID: hello.deviceID))
        XCTAssertEqual(authorizer.authorize(certificateDER: Data(repeating: 0x45, count: 128)), .rejected)
    }

    func testPairingModeAdmitsOnlyOneUnknownCertificate() throws {
        let store = try EkoStore(path: temporaryDatabasePath())
        let pairingMode = PairingModeController()
        _ = try pairingMode.activate()
        let authorizer = StorePeerAuthorizer(store: store, pairingMode: pairingMode)
        let first = Data(repeating: 1, count: 96)
        let second = Data(repeating: 2, count: 96)
        XCTAssertEqual(
            authorizer.authorize(certificateDER: first),
            .pairing(fingerprint: EkoCrypto.fingerprint(of: first))
        )
        XCTAssertEqual(authorizer.authorize(certificateDER: second), .rejected)
        XCTAssertEqual(
            authorizer.authorize(certificateDER: first),
            .pairing(fingerprint: EkoCrypto.fingerprint(of: first))
        )
    }

    func testQRTokenValidationDoesNotConsumeUntilMarked() throws {
        let pairingMode = PairingModeController()
        let invitation = try pairingMode.activate()
        XCTAssertTrue(pairingMode.redeemableToken(invitation.token))
        // Validation alone never burns the token: a disconnect before the consumption
        // record and pairing attempt commit leaves the token redeemable.
        XCTAssertTrue(pairingMode.redeemableToken(invitation.token))
        pairingMode.markTokenConsumed()
        XCTAssertFalse(pairingMode.redeemableToken(invitation.token))
        XCTAssertNil(pairingMode.currentInvitation())
    }

    func testQRTokenFailuresAreRateLimited() throws {
        let pairingMode = PairingModeController()
        let invitation = try pairingMode.activate()
        for _ in 0..<5 {
            XCTAssertFalse(pairingMode.redeemableToken("wrong-token"))
        }
        XCTAssertFalse(pairingMode.acceptsNewPairingAttempts)
        XCTAssertFalse(pairingMode.redeemableToken(invitation.token))
    }

    func testPersistedPendingPairCanResumeAfterPairingModeIsGone() throws {
        let now = Date(timeIntervalSince1970: 1_753_351_200)
        let store = try EkoStore(path: temporaryDatabasePath(), clock: FixedClock(date: now))
        let certificate = Data(repeating: 0x42, count: 128)
        let fingerprint = EkoCrypto.fingerprint(of: certificate)
        try store.savePairingAttempt(PersistedPairingAttempt(
            attemptID: "00112233445566778899aabbccddeeff",
            deviceID: fingerprint,
            deviceName: "Pending Phone",
            localDeviceName: "Pending Mac",
            peerCertificateDER: certificate,
            localNonce: Data(repeating: 1, count: 32),
            localCommitment: Data(repeating: 2, count: 32),
            peerCommitment: Data(repeating: 3, count: 32),
            peerNonce: Data(repeating: 4, count: 32),
            verificationCode: "12345678",
            transcriptHash: Data(repeating: 5, count: 32),
            qrPreauthenticated: false,
            localConfirmed: true,
            peerConfirmed: false,
            highestConnectionEpoch: 1,
            outboxGeneration: testGenerationA,
            initialCursor: nil,
            expiresAt: now.addingTimeInterval(300)
        ))

        let authorizer = StorePeerAuthorizer(store: store, pairingMode: PairingModeController())
        XCTAssertEqual(authorizer.authorize(certificateDER: certificate), .pairing(fingerprint: fingerprint))
    }

    func testPendingPairEpochHighWaterIsStrictAndDurable() throws {
        let store = try EkoStore(path: temporaryDatabasePath())
        let certificate = Data(repeating: 0x52, count: 128)
        let fingerprint = EkoCrypto.fingerprint(of: certificate)
        try store.reservePairingEpoch(deviceID: fingerprint, certificateDER: certificate, epoch: 9)
        XCTAssertThrowsError(try store.reservePairingEpoch(
            deviceID: fingerprint,
            certificateDER: certificate,
            epoch: 9
        ))
        XCTAssertNoThrow(try store.reservePairingEpoch(
            deviceID: fingerprint,
            certificateDER: certificate,
            epoch: 10
        ))
    }

    func testRevokedPeerGetsOnlyRestrictedAdmission() throws {
        let path = try temporaryDatabasePath()
        let store = try EkoStore(path: path)
        let certificate = Data(repeating: 0x31, count: 128)
        let hello = testHello(certificateDER: certificate)
        _ = try store.confirmPairing(
            hello: hello,
            certificateDER: certificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: nil
        )
        try store.beginUnpair(
            deviceID: hello.deviceID,
            message: UnpairMessage(
                unpairID: "deadbeef-0000-4000-8000-000000000001",
                initiatorID: String(repeating: "a", count: 64),
                peerID: hello.deviceID,
                reason: .userRequest
            ),
            deleteHistory: false
        )
        let authorizer = StorePeerAuthorizer(store: store, pairingMode: PairingModeController())
        XCTAssertEqual(authorizer.authorize(certificateDER: certificate), .revoked(deviceID: hello.deviceID))
    }
}
