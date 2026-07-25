import Foundation

public struct PairingSASResult: Equatable, Sendable {
    public let verificationCode: String
    public let transcriptHash: Data

    public init(verificationCode: String, transcriptHash: Data) {
        self.verificationCode = verificationCode
        self.transcriptHash = transcriptHash
    }
}

public struct PendingPairing: Equatable, Sendable {
    public let attemptID: String
    public let deviceID: String
    public let deviceName: String
    public let verificationCode: String
    public let certificateFingerprint: String
    public let qrPreauthenticated: Bool
    public let expiresAt: Date

    public init(
        attemptID: String,
        deviceID: String,
        deviceName: String,
        verificationCode: String,
        certificateFingerprint: String,
        qrPreauthenticated: Bool,
        expiresAt: Date
    ) {
        self.attemptID = attemptID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.verificationCode = verificationCode
        self.certificateFingerprint = certificateFingerprint
        self.qrPreauthenticated = qrPreauthenticated
        self.expiresAt = expiresAt
    }
}

public enum PairingSAS {
    private static let commitDomain = Data("eko-pair-commit-v1".utf8)
    private static let sasDomain = Data("eko-pair-sas-v1".utf8)

    public static func commitment(attemptID: String, certificateDER: Data, nonce: Data) throws -> Data {
        guard ProtocolCodec.isPairAttemptID(attemptID),
              let attemptBytes = Data(hex: attemptID), attemptBytes.count == 16,
              !certificateDER.isEmpty, nonce.count == 32 else {
            throw EkoCoreError.invalidData("invalid pairing commitment input")
        }
        var input = commitDomain
        try input.appendLengthPrefixed(attemptBytes)
        try input.appendLengthPrefixed(certificateDER)
        input.append(nonce)
        return EkoCrypto.sha256(input)
    }

    public static func verify(
        commitment expected: Data,
        attemptID: String,
        certificateDER: Data,
        revealedNonce: Data
    ) throws -> Bool {
        let actual = try commitment(attemptID: attemptID, certificateDER: certificateDER, nonce: revealedNonce)
        return EkoCrypto.constantTimeEqual(expected, actual)
    }

    public static func derive(
        attemptID: String,
        firstCertificateDER: Data,
        firstNonce: Data,
        secondCertificateDER: Data,
        secondNonce: Data
    ) throws -> PairingSASResult {
        guard ProtocolCodec.isPairAttemptID(attemptID),
              let attemptBytes = Data(hex: attemptID), attemptBytes.count == 16,
              !firstCertificateDER.isEmpty, !secondCertificateDER.isEmpty,
              firstCertificateDER != secondCertificateDER,
              firstNonce.count == 32, secondNonce.count == 32 else {
            throw EkoCoreError.invalidData("invalid SAS input")
        }

        let tuples = [
            (certificate: firstCertificateDER, nonce: firstNonce),
            (certificate: secondCertificateDER, nonce: secondNonce),
        ].sorted { left, right in
            left.certificate.lexicographicallyPrecedes(right.certificate)
        }

        var sasInput = sasDomain
        try sasInput.appendLengthPrefixed(attemptBytes)
        for tuple in tuples {
            var encodedTuple = Data()
            try encodedTuple.appendLengthPrefixed(tuple.certificate)
            try encodedTuple.appendLengthPrefixed(tuple.nonce)
            try sasInput.appendLengthPrefixed(encodedTuple)
        }
        let sasHash = EkoCrypto.sha256(sasInput)
        let code = Data(sasHash.prefix(4)).hexUppercased
        return PairingSASResult(
            verificationCode: code,
            transcriptHash: sasHash
        )
    }
}

extension Data {
    mutating func appendLengthPrefixed(_ value: Data) throws {
        guard value.count <= Int(UInt32.max) else {
            throw EkoCoreError.invalidData("length-prefixed value is too large")
        }
        appendUInt32(UInt32(value.count))
        append(value)
    }
}
