import Crypto
import Foundation

public enum EkoCoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidData(String)
    case protocolViolation(String)
    case invalidState(String)
    case sequenceConflict
    case frameTooLarge
    case storage(String)
    case identity(String)
    case unauthorized
    case superseded
    case incompatibleProtocol
    case retiredGeneration
    case pairingUnavailable
    case pairingExpired
    case pairingRejected
    case timedOut
    case transportClosed

    public var errorDescription: String? {
        switch self {
        case .invalidData(let detail): return "Invalid data: \(detail)"
        case .protocolViolation(let detail): return "Protocol violation: \(detail)"
        case .invalidState(let detail): return "Invalid protocol state: \(detail)"
        case .sequenceConflict: return "A sequence position conflicts with committed state."
        case .frameTooLarge: return "The frame exceeds the protocol size limit."
        case .storage(let detail): return "Storage error: \(detail)"
        case .identity(let detail): return "Identity error: \(detail)"
        case .unauthorized: return "The peer is not authorized."
        case .superseded: return "The connection was superseded."
        case .incompatibleProtocol: return "No compatible protocol version is available."
        case .retiredGeneration: return "The peer attempted to reuse a retired generation."
        case .pairingUnavailable: return "Pairing mode is not available."
        case .pairingExpired: return "The pairing attempt expired."
        case .pairingRejected: return "The pairing attempt was rejected."
        case .timedOut: return "The operation timed out."
        case .transportClosed: return "The transport is closed."
        }
    }
}

public protocol EkoClock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemEkoClock: EkoClock {
    public init() {}

    public func now() -> Date { Date() }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

public enum EkoCrypto {
    public static func sha256(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    public static func fingerprint(of certificateDER: Data) -> String {
        sha256(certificateDER).hexLowercased
    }

    public static func randomBytes(count: Int) throws -> Data {
        guard count > 0 else { throw EkoCoreError.invalidData("random byte count must be positive") }
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}

extension Data {
    public var hexLowercased: String {
        map { String(format: "%02x", $0) }.joined()
    }

    public var hexUppercased: String {
        map { String(format: "%02X", $0) }.joined()
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    func uint32(at index: Int) -> UInt32 {
        let first = UInt32(self[index]) << 24
        let second = UInt32(self[index + 1]) << 16
        let third = UInt32(self[index + 2]) << 8
        return first | second | third | UInt32(self[index + 3])
    }
}

extension String {
    var isLowercaseSHA256: Bool {
        count == 64 && utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    var normalizedForSearch: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    var escapedForLike: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}

func millisecondsSinceEpoch(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000).rounded(.towardZero))
}

func dateFromMilliseconds(_ value: Int64) -> Date {
    Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
}
