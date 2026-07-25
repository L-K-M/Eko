import Foundation

public struct PairingInvitation: Equatable, Sendable {
    public let token: String
    public let expiresAt: Date

    public init(token: String, expiresAt: Date) {
        self.token = token
        self.expiresAt = expiresAt
    }
}

public enum TLSAdmission: Equatable, Sendable {
    case paired(deviceID: String)
    case pairing(fingerprint: String)
    case revoked(deviceID: String)
    case rejected

    public var isAccepted: Bool {
        if case .rejected = self { return false }
        return true
    }
}

public final class PairingModeController: @unchecked Sendable {
    private struct State {
        var token: String?
        var expiresAt: Date
        var admittedFingerprint: String?
        var failedTokenAttempts: Int
    }

    private let lock = NSLock()
    private let clock: any EkoClock
    private var state: State?

    public init(clock: any EkoClock = SystemEkoClock()) {
        self.clock = clock
    }

    public func activate(duration: TimeInterval = 5 * 60) throws -> PairingInvitation {
        let tokenBytes = try EkoCrypto.randomBytes(count: 32)
        let token = tokenBytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let expiresAt = clock.now().addingTimeInterval(min(max(duration, 30), 10 * 60))
        lock.ekoWithLock {
            state = State(token: token, expiresAt: expiresAt, admittedFingerprint: nil, failedTokenAttempts: 0)
        }
        return PairingInvitation(token: token, expiresAt: expiresAt)
    }

    public func deactivate() {
        lock.ekoWithLock { state = nil }
    }

    public func admitUnknown(certificateDER: Data) -> TLSAdmission {
        let fingerprint = EkoCrypto.fingerprint(of: certificateDER)
        return lock.ekoWithLock {
            guard var current = validStateLocked() else { return .rejected }
            if let admitted = current.admittedFingerprint, admitted != fingerprint { return .rejected }
            current.admittedFingerprint = fingerprint
            state = current
            return .pairing(fingerprint: fingerprint)
        }
    }

    /// Validates a QR token candidate without consuming it. Consumption happens only
    /// through `markTokenConsumed` after the token and its pairing attempt have been
    /// persisted atomically, so a disconnect before persistence never burns the token.
    public func redeemableToken(_ candidate: String?) -> Bool {
        lock.ekoWithLock {
            guard var current = validStateLocked(), let candidate else { return false }
            guard let token = current.token else { return false }
            let valid = EkoCrypto.constantTimeEqual(Data(candidate.utf8), Data(token.utf8))
            if !valid {
                current.failedTokenAttempts += 1
                state = current.failedTokenAttempts >= 5 ? nil : current
            }
            return valid
        }
    }

    /// Marks the issued token as consumed after its durable consumption record committed.
    public func markTokenConsumed() {
        lock.ekoWithLock {
            guard var current = state else { return }
            current.token = nil
            state = current
        }
    }

    /// Whether an unexpired pairing mode currently admits new pairing attempts.
    public var acceptsNewPairingAttempts: Bool {
        lock.ekoWithLock { validStateLocked() != nil }
    }

    public func currentInvitation() -> PairingInvitation? {
        lock.ekoWithLock {
            guard let current = validStateLocked(), let token = current.token else { return nil }
            return PairingInvitation(token: token, expiresAt: current.expiresAt)
        }
    }

    private func validStateLocked() -> State? {
        guard let current = state, current.expiresAt > clock.now() else {
            state = nil
            return nil
        }
        return current
    }
}

public protocol PeerAuthorizing: Sendable {
    func authorize(certificateDER: Data) -> TLSAdmission
}

public final class StorePeerAuthorizer: PeerAuthorizing, @unchecked Sendable {
    private let store: EkoStore
    private let pairingMode: PairingModeController

    public init(store: EkoStore, pairingMode: PairingModeController) {
        self.store = store
        self.pairingMode = pairingMode
    }

    public func authorize(certificateDER: Data) -> TLSAdmission {
        do {
            switch try store.peerAuthorization(for: certificateDER) {
            case .paired(let deviceID): return .paired(deviceID: deviceID)
            case .pendingPairing(let deviceID): return .pairing(fingerprint: deviceID)
            case .revoked(let deviceID): return .revoked(deviceID: deviceID)
            case .unknown: return pairingMode.admitUnknown(certificateDER: certificateDER)
            case .certificateMismatch: return .rejected
            }
        } catch {
            return .rejected
        }
    }
}

private extension NSLock {
    func ekoWithLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
