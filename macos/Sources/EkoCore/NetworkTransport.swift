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
        receiveNext()
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    let frames = try self.decoder.append(data)
                    for frame in frames {
                        switch frame {
                        case .json(let payload):
                            let message = try ProtocolCodec.decode(payload)
                            try self.inbox.yield(message, encodedByteCount: payload.count + 5)
                        }
                    }
                } catch {
                    self.inbox.finish(error: error)
                    self.connection.cancel()
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
            } else {
                self.receiveNext()
            }
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
    private let lock = NSLock()
    private let maximumQueuedBytes: Int

    init(maximumQueuedMessages: Int = 256, maximumQueuedBytes: Int = 16 * 1_024 * 1_024) {
        precondition(maximumQueuedMessages > 0)
        precondition(maximumQueuedBytes > 0)
        messages = Array(repeating: nil, count: maximumQueuedMessages)
        self.maximumQueuedBytes = maximumQueuedBytes
    }

    func next() async throws -> WireMessage? {
        try Task.checkCancellation()
        let id = UUID()
        let cancellation = CancellationToken()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<WireMessage?, Error>?
                lock.lock()
                if cancellation.isCancelled {
                    result = .failure(CancellationError())
                } else if messageCount > 0 {
                    let queued = messages[messageHead]!
                    messages[messageHead] = nil
                    messageHead = (messageHead + 1) % messages.count
                    messageCount -= 1
                    queuedByteCount -= queued.encodedByteCount
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
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            cancellation.cancel()
            self.cancelWaiter(id: id)
        }
    }

    func yield(_ message: WireMessage, encodedByteCount: Int) throws {
        precondition(encodedByteCount >= 0)
        let continuation: CheckedContinuation<WireMessage?, Error>?
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        if let waiter {
            self.waiter = nil
            continuation = waiter.continuation
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
        }
        lock.unlock()
        continuation?.resume(returning: message)
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
