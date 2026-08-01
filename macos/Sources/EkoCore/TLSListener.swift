import Foundation
import Network
import Security

public enum TLSListenerState: Equatable, Sendable {
    case stopped
    case starting
    case ready(port: UInt16, usedFallback: Bool)
    case waiting(String)
    case failed(String)
}

public final class TLSListener: @unchecked Sendable {
    public typealias StateHandler = @Sendable (TLSListenerState) -> Void

    public typealias EventHandler = @Sendable (String) -> Void

    private let identity: DeviceIdentity
    private let authorizer: any PeerAuthorizing
    private let sessionManager: SessionManager
    private let queue = DispatchQueue(label: "com.eko.listener")
    private let verificationQueue = DispatchQueue(label: "com.eko.listener.verify", qos: .userInitiated)
    private let limiter = ConnectionLimiter()
    private let stateHandler: StateHandler
    private let events: EventHandler
    private var listener: NWListener?
    private var preferredPort: UInt16 = 48_808
    private var fallbackAttempted = false

    public init(
        identity: DeviceIdentity,
        authorizer: any PeerAuthorizing,
        sessionManager: SessionManager,
        stateHandler: @escaping StateHandler = { _ in },
        events: @escaping EventHandler = { _ in }
    ) {
        self.identity = identity
        self.authorizer = authorizer
        self.sessionManager = sessionManager
        self.stateHandler = stateHandler
        self.events = events
    }

    public func start(preferredPort: UInt16 = 48_808) async throws -> UInt16 {
        self.preferredPort = preferredPort
        self.fallbackAttempted = false
        stateHandler(.starting)
        return try await startListener(port: preferredPort)
    }

    public func stop() {
        queue.async { [weak self] in
            self?.listener?.cancel()
            self?.listener = nil
            self?.stateHandler(.stopped)
        }
    }

    private func startListener(port: UInt16?) async throws -> UInt16 {
        let parameters = try makeParameters()
        let nwPort = port.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        let listener = try NWListener(using: parameters, on: nwPort)
        self.listener = listener
        configureNewConnectionHandler(listener)

        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    guard let actualPort = listener.port?.rawValue else {
                        if !resumed {
                            resumed = true
                            continuation.resume(throwing: EkoCoreError.transportClosed)
                        }
                        return
                    }
                    self.stateHandler(.ready(port: actualPort, usedFallback: self.fallbackAttempted))
                    if !resumed {
                        resumed = true
                        continuation.resume(returning: actualPort)
                    }

                case .waiting(let error):
                    self.stateHandler(.waiting(error.localizedDescription))

                case .failed(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                    self.stateHandler(.failed(error.localizedDescription))

                case .cancelled:
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: EkoCoreError.transportClosed)
                    }

                case .setup:
                    break

                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func startWithPortFallback(preferredPort: UInt16 = 48_808) async throws -> UInt16 {
        do {
            return try await start(preferredPort: preferredPort)
        } catch {
            listener?.cancel()
            fallbackAttempted = true
            return try await startListener(port: nil)
        }
    }

    private func makeParameters() throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let securityOptions = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_max_tls_protocol_version(securityOptions, .TLSv13)
        sec_protocol_options_set_peer_authentication_required(securityOptions, true)
        guard let localIdentity = sec_identity_create(identity.securityIdentity) else {
            throw EkoCoreError.identity("Security.framework could not bridge SecIdentity")
        }
        sec_protocol_options_set_local_identity(securityOptions, localIdentity)

        let authorizer = self.authorizer
        sec_protocol_options_set_verify_block(securityOptions, { _, trust, complete in
            let trustReference = sec_trust_copy_ref(trust).takeRetainedValue()
            // Build the chain before copying it: SecTrustCopyCertificateChain
            // is only defined after an evaluation. The verdict is deliberately
            // ignored — peers present self-signed certificates and admission
            // is decided by the exact-DER pin, not by CA trust.
            _ = SecTrustSetNetworkFetchAllowed(trustReference, false)
            _ = SecTrustEvaluateWithError(trustReference, nil)
            guard let chain = SecTrustCopyCertificateChain(trustReference) as? [SecCertificate],
                  let leaf = chain.first else {
                complete(false)
                return
            }
            let leafDER = SecCertificateCopyData(leaf) as Data
            complete(authorizer.authorize(certificateDER: leafDER).isAccepted)
        }, verificationQueue)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.keepaliveInterval = 10
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 10

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        return parameters
    }

    private func configureNewConnectionHandler(_ listener: NWListener) {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            let source = Self.sourceKey(connection.endpoint)
            guard self.limiter.begin(source: source) else {
                self.events("rate-limited connection from \(source)")
                connection.cancel()
                return
            }
            let transport = NWFrameTransport(connection: connection)
            Task {
                do {
                    let peerDER = try await transport.start(timeout: 5)
                    self.limiter.end()
                    let admission = self.authorizer.authorize(certificateDER: peerDER)
                    guard admission.isAccepted else {
                        self.events("connection from \(source) closed: peer not admitted")
                        await transport.close()
                        return
                    }
                    await self.sessionManager.run(
                        admission: admission,
                        peerCertificateDER: peerDER,
                        transport: transport
                    )
                } catch {
                    self.limiter.end()
                    // The TLS verify block's own rejections also surface here,
                    // as a connection that failed before becoming ready.
                    self.events("connection from \(source) failed during TLS setup: \(error.localizedDescription)")
                    await transport.close()
                }
            }
        }
    }

    private static func sourceKey(_ endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint { return String(describing: host) }
        return String(describing: endpoint)
    }
}

private final class ConnectionLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var unauthenticatedCount = 0
    private var attempts: [String: [Date]] = [:]
    private var allAttempts: [Date] = []
    private let maximumUnauthenticated = 8
    private let maximumAttemptsPerMinute = 12
    // Per-source throttling is keyed on an address the attacker rotates freely
    // (IPv6 privacy addresses, multiple hosts). This source-independent ceiling
    // bounds how fast the unauthenticated slots can be churned in total, so a
    // half-open flood cannot starve a legitimate phone indefinitely.
    private let maximumTotalAttemptsPerMinute = 60

    func begin(source: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let cutoff = now.addingTimeInterval(-60)
        allAttempts = allAttempts.filter { $0 >= cutoff }
        var recent = attempts[source, default: []].filter { $0 >= cutoff }
        guard unauthenticatedCount < maximumUnauthenticated,
              recent.count < maximumAttemptsPerMinute,
              allAttempts.count < maximumTotalAttemptsPerMinute else {
            attempts[source] = recent
            return false
        }
        recent.append(now)
        attempts[source] = recent
        allAttempts.append(now)
        unauthenticatedCount += 1
        if attempts.count > 128 {
            attempts = attempts.filter { $0.value.contains(where: { $0 >= cutoff }) }
        }
        return true
    }

    func end() {
        lock.lock()
        unauthenticatedCount = max(0, unauthenticatedCount - 1)
        lock.unlock()
    }
}

public enum NetworkPathState: Equatable, Sendable {
    case satisfied
    case unsatisfied
    case localNetworkDenied
    case requiresConnection
}

public final class NetworkPathObserver: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.eko.path-monitor")
    private let handler: @Sendable (NetworkPathState) -> Void

    public init(handler: @escaping @Sendable (NetworkPathState) -> Void) {
        self.handler = handler
    }

    public func start() {
        monitor.pathUpdateHandler = { [handler] path in
            if path.status == .satisfied {
                handler(.satisfied)
            } else if #available(macOS 15.0, *), path.unsatisfiedReason == .localNetworkDenied {
                handler(.localNetworkDenied)
            } else if path.status == .requiresConnection {
                handler(.requiresConnection)
            } else {
                handler(.unsatisfied)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }
}
