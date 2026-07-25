import XCTest
@testable import EkoCore

final class PairingSASTests: XCTestCase {
    func testSharedCommitmentVectors() throws {
        let vectors = try loadVectors()
        for participant in vectors.participants.values {
            let commitment = try PairingSAS.commitment(
                attemptID: vectors.attemptID,
                certificateDER: try XCTUnwrap(Data(hex: participant.certDerHex)),
                nonce: try XCTUnwrap(Data(hex: participant.nonceHex))
            )
            XCTAssertEqual(commitment.hexLowercased, participant.commitment)
        }
    }

    func testSharedSASVectorIsSymmetric() throws {
        let vectors = try loadVectors()
        let phone = try XCTUnwrap(vectors.participants["phone"])
        let mac = try XCTUnwrap(vectors.participants["mac"])
        let phoneCertificate = try XCTUnwrap(Data(hex: phone.certDerHex))
        let phoneNonce = try XCTUnwrap(Data(hex: phone.nonceHex))
        let macCertificate = try XCTUnwrap(Data(hex: mac.certDerHex))
        let macNonce = try XCTUnwrap(Data(hex: mac.nonceHex))

        let result = try PairingSAS.derive(
            attemptID: vectors.attemptID,
            firstCertificateDER: phoneCertificate,
            firstNonce: phoneNonce,
            secondCertificateDER: macCertificate,
            secondNonce: macNonce
        )
        let reversed = try PairingSAS.derive(
            attemptID: vectors.attemptID,
            firstCertificateDER: macCertificate,
            firstNonce: macNonce,
            secondCertificateDER: phoneCertificate,
            secondNonce: phoneNonce
        )

        XCTAssertEqual(result, reversed)
        XCTAssertEqual(result.transcriptHash.hexLowercased, vectors.expected.transcriptHash)
        XCTAssertEqual(result.verificationCode, vectors.expected.verificationCode)
    }

    func testAttemptAndNonceOwnerBindingsUseSharedVectors() throws {
        let vectors = try loadVectors()
        let phone = try XCTUnwrap(vectors.participants["phone"])
        let mac = try XCTUnwrap(vectors.participants["mac"])
        let phoneCertificate = try XCTUnwrap(Data(hex: phone.certDerHex))
        let phoneNonce = try XCTUnwrap(Data(hex: phone.nonceHex))
        let macCertificate = try XCTUnwrap(Data(hex: mac.certDerHex))
        let macNonce = try XCTUnwrap(Data(hex: mac.nonceHex))
        let attemptBinding = try XCTUnwrap(vectors.additionalVectors.first { $0.id == "attempt-id-binding" })
        let swappedOwners = try XCTUnwrap(vectors.additionalVectors.first { $0.id == "nonce-owner-binding-negative" })

        let rebound = try PairingSAS.derive(
            attemptID: try XCTUnwrap(attemptBinding.attemptID),
            firstCertificateDER: phoneCertificate,
            firstNonce: phoneNonce,
            secondCertificateDER: macCertificate,
            secondNonce: macNonce
        )
        XCTAssertEqual(rebound.transcriptHash.hexLowercased, attemptBinding.transcriptHash)
        XCTAssertEqual(rebound.verificationCode, attemptBinding.verificationCode)

        let swapped = try PairingSAS.derive(
            attemptID: vectors.attemptID,
            firstCertificateDER: phoneCertificate,
            firstNonce: macNonce,
            secondCertificateDER: macCertificate,
            secondNonce: phoneNonce
        )
        XCTAssertEqual(swapped.transcriptHash.hexLowercased, swappedOwners.transcriptHash)
        XCTAssertEqual(swapped.verificationCode, swappedOwners.verificationCode)
        XCTAssertNotEqual(swapped, rebound)
    }

    func testNonceMustBeExactly32Bytes() throws {
        let vectors = try loadVectors()
        let phone = try XCTUnwrap(vectors.participants["phone"])
        XCTAssertThrowsError(try PairingSAS.commitment(
            attemptID: vectors.attemptID,
            certificateDER: try XCTUnwrap(Data(hex: phone.certDerHex)),
            nonce: Data(repeating: 0, count: 31)
        ))
    }

    private func loadVectors() throws -> SASVectors {
        try JSONDecoder().decode(SASVectors.self, from: Data(contentsOf: protocolVectorURL("sas.json")))
    }
}

private struct SASVectors: Decodable {
    let attemptID: String
    let participants: [String: Participant]
    let expected: Expected
    let additionalVectors: [Additional]

    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id"
        case participants, expected
        case additionalVectors = "additional_vectors"
    }

    struct Participant: Decodable {
        let certDerHex: String
        let nonceHex: String
        let commitment: String

        enum CodingKeys: String, CodingKey {
            case certDerHex = "cert_der_hex"
            case nonceHex = "nonce_hex"
            case commitment
        }
    }

    struct Expected: Decodable {
        let transcriptHash: String
        let verificationCode: String

        enum CodingKeys: String, CodingKey {
            case transcriptHash = "transcript_hash"
            case verificationCode = "verification_code"
        }
    }

    struct Additional: Decodable {
        let id: String
        let attemptID: String?
        let transcriptHash: String
        let verificationCode: String

        enum CodingKeys: String, CodingKey {
            case id
            case attemptID = "attempt_id"
            case transcriptHash = "transcript_hash"
            case verificationCode = "verification_code"
        }
    }
}
