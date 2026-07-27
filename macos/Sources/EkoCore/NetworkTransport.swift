import Foundation
import Network
import Security

public final class NWFrameTransport: SessionTransport, @unchecked Sendable {
    public let id = UUID()
    public let remoteEndpointDescription: String

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let inbox = MessageInbox()
    private let sendQueue: DispatchQueue
    private var decoder = FrameDecoder()
    private var startContinuation: CheckedContinuation<Data, Error>?
    private var startFinished = false
    private var receiveStarted = false

    public init(connection: NWConnection) {
        self.connection = connection
        self.remoteEndpointDescription = String(describing: connection.endpoint)
        self.queue = DispatchQueue(label: "com.eko.transport.\(id.uuidString)")
        self.sendQueue = DispatchQueue(label: "com.eko.transport.send.\(id.uuidString)")
    }

    public func start(timeout: TimeInterval = 10) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !startFinished, startContinuation == nil else {
                        continuation.resume(throwing: EkoCoreError.protocolViolation("transport was started twice"))
                        return
                    }
                    startContinuation = continuation
                    connection.stateUpdateHandler = { [weak self] state in
                        self?.handleState(state)
                    }
                    connection.start(queue: queue)
                    queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                        guard let self, !self.startFinished else { return }
                        self.finishStart(.failure(EkoCoreError.timedOut))
                        self.connection.cancel()
                    }
                }
            }
        } onCancel: {
            self.connection.cancel()
        }
    }

    public func receive() async throws -> WireMessage? {
        try await inbox.next()
    }

    public func send(_ message: WireMessage) async throws {
        let data = try FrameEncoder.encode(message)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sendQueue.async { [connection] in
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
            }
        }
    }

    public func close() async {
        connection.cancel()
        inbox.finish(error: nil)
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !startFinished else { return }
            do {
                let certificateDER = try peerLeafCertificateDER()
                finishStart(.success(certificateDER))
                startReceiveLoop()
            } catch {
                finishStart(.failure(error))
                connection.cancel()
            }

        case .failed(let error):
            finishStart(.failure(error))
            inbox.finish(error: error)

        case .cancelled:
            if !startFinished { finishStart(.failure(EkoCoreError.transportClosed)) }
            inbox.finish(error: nil)

        case .waiting, .preparing, .setup:
            break

        @unknown default:
            break
        }
    }

    private func finishStart(_ result: Result<Data, Error>) {
        guard !startFinished else { return }
        startFinished = true
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(with: result)
    }

    private func peerLeafCertificateDER() throws -> Data {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            throw EkoCoreError.unauthorized
        }
        var leafDER: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            guard leafDER == nil else { return }
            let reference = sec_certificate_copy_ref(certificate).takeRetainedValue()
            leafDER = SecCertificateCopyData(reference) as Data
        }
        guard let leafDER else { throw EkoCoreError.unauthorized }
        return leafDER
    }

    private func startReceiveLoop() {
        guard !receiveStarted else { return }
        receiveStarted = true
        // When the consumer drains a paused queue below the low-water mark,
        // re-arm the receive loop. NWConnection.receive is safe to call from
        // the resuming thread; its callback lands on the connection queue.
        inbox.setOnResume { [weak self] in self?.receiveNext() }
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            var keepReceiving = true
            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        switch frame {
                        case .json(let payload):
                            let message = try ProtocolCodec.decode(payload)
                            let proceed = try self.inbox.yield(
                                message,
                                encodedByteCount: payload.count + FrameLayout.headerByteCount
                            )
                            keepReceiving = keepReceiving && proceed
                        }
                    }
                } catch {
                    self.inbox.finish(error: error)
                    self.terminate(after: error)
                    return
                }
            }
            if let error {
                self.inbox.finish(error: error)
                self.connection.cancel()
            } else if complete {
                do {
                    try self.decoder.finish()
                    self.inbox.finish(error: nil)
                    // A clean peer EOF is the one exit that skipped cancel(),
                    // leaving the socket in CLOSE_WAIT until deallocation.
                    self.connection.cancel()
                } catch {
                    self.inbox.finish(error: error)
                    self.connection.cancel()
                }
            } else if keepReceiving {
                self.receiveNext()
            }
            // Paused: no re-arm — the inbox's resume handler restarts the
            // loop once the consumer drains below the low-water mark.
        }
    }

    /// On resource exhaustion, tell the peer why before tearing down — a bare
    /// TCP reset reads as a network flake and invites an identical retry. The
    /// frame is best effort: whether or not it flushes, the connection dies.
    private func terminate(after error: Error) {
        guard case EkoCoreError.resourceExhausted = error,
              let frame = try? FrameEncoder.encode(.error(ErrorMessage(code: "protocol_error", message: "inbound queue exhausted"))) else {
            connection.cancel()
            return
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.connection.cancel()
        }
    }
}

final class MessageInbox: @unchecked Sendable {
    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private struct QueuedMessage {
        let message: WireMessage
        let encodedByteCount: Int
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<WireMessage?, Error>
    }

    private var messages: [QueuedMessage?]
    private var messageHead = 0
    private var messageCount = 0
    private var queuedByteCount = 0
    private var waiter: Waiter?
    private var terminalError: Error?
    private var finished = false
    private var paused = false
    private var onResume: (() -> Void)?
    private let lock = NSLock()
    private let maximumQueuedBytes: Int
    private let pauseMessageCount: Int
    private let resumeMessageCount: Int
    private let pauseByteCount: Int
    private let resumeByteCount: Int

    // The hard caps are an attack backstop, not flow control: with the
    // high/low-water pause below, a legitimate consumer that merely lags
    // (a 2 000-event backlog replay drains at database-write speed) stops
    // the receive loop long before the caps, and TCP backpressure holds the
    // rest on the peer. Only a producer that keeps yielding while paused —
    // a logic error or a peer exploiting a stalled consumer — can trip them.
    init(maximumQueuedMessages: Int = 4_096, maximumQueuedBytes: Int = 16 * 1_024 * 1_024) {
        precondition(maximumQueuedMessages > 0)
        precondition(maximumQueuedBytes > 0)
        messages = Array(repeating: nil, count: maximumQueuedMessages)
        self.maximumQueuedBytes = maximumQueuedBytes
        pauseMessageCount = max(1, maximumQueuedMessages / 2)
        resumeMessageCount = maximumQueuedMessages / 4
        pauseByteCount = max(1, maximumQueuedBytes / 2)
        resumeByteCount = maximumQueuedBytes / 4
    }

    /// The producer's re-arm hook: invoked exactly once per pause, when a
    /// drain brings the queue back under the low-water marks.
    func setOnResume(_ handler: @escaping () -> Void) {
        lock.lock()
        onResume = handler
        lock.unlock()
    }

    func next() async throws -> WireMessage? {
        try Task.checkCancellation()
        let id = UUID()
        let cancellation = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<WireMessage?, Error>?
                var resume: (() -> Void)?
                lock.lock()
                if cancellation.isCancelled {
                    result = .failure(CancellationError())
                } else if messageCount > 0 {
                    let queued = messages[messageHead]!
                    messages[messageHead] = nil
                    messageHead = (messageHead + 1) % messages.count
                    messageCount -= 1
                    queuedByteCount -= queued.encodedByteCount
                    if paused, messageCount <= resumeMessageCount, queuedByteCount <= resumeByteCount {
                        paused = false
                        resume = onResume
                    }
                    result = .success(queued.message)
                } else if let terminalError {
                    result = .failure(terminalError)
                } else if finished {
                    result = .success(nil)
                } else if waiter != nil {
                    result = .failure(EkoCoreError.protocolViolation("concurrent receives are not allowed"))
                } else {
                    waiter = Waiter(id: id, continuation: continuation)
                    result = nil
                }
                lock.unlock()
                resume?()
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            cancellation.cancel()
            self.cancelWaiter(id: id)
        }
    }

    /// Returns whether the producer should keep receiving. `false` means the
    /// queue crossed its high-water mark: stop re-arming reads (letting TCP
    /// flow control hold the peer) until the resume handler fires.
    @discardableResult
    func yield(_ message: WireMessage, encodedByteCount: Int) throws -> Bool {
        precondition(encodedByteCount >= 0)
        let continuation: CheckedContinuation<WireMessage?, Error>?
        let keepReceiving: Bool
        lock.lock()
        guard !finished else {
            lock.unlock()
            return false
        }
        if let waiter {
            self.waiter = nil
            continuation = waiter.continuation
            keepReceiving = true
        } else {
            if messageCount == messages.count || encodedByteCount > maximumQueuedBytes - queuedByteCount {
                finished = true
                terminalError = EkoCoreError.resourceExhausted
                lock.unlock()
                throw EkoCoreError.resourceExhausted
            }
            let tail = (messageHead + messageCount) % messages.count
            messages[tail] = QueuedMessage(message: message, encodedByteCount: encodedByteCount)
            messageCount += 1
            queuedByteCount += encodedByteCount
            continuation = nil
            if messageCount >= pauseMessageCount || queuedByteCount >= pauseByteCount {
                paused = true
                keepReceiving = false
            } else {
                keepReceiving = true
            }
        }
        lock.unlock()
        continuation?.resume(returning: message)
        return keepReceiving
    }

    func finish(error: Error?) {
        let continuation: CheckedContinuation<WireMessage?, Error>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        terminalError = error
        if let waiter {
            self.waiter = nil
            continuation = waiter.continuation
        } else {
            continuation = nil
        }
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: nil)
        }
    }

    private func cancelWaiter(id: UUID) {
        let continuation: CheckedContinuation<WireMessage?, Error>?
        lock.lock()
        if waiter?.id == id, let waiter {
            self.waiter = nil
            continuation = waiter.continuation
        } else {
            continuation = nil
        }
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }
}
