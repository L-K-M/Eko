import XCTest
@testable import EkoCore

final class MessageInboxTests: XCTestCase {
    func testQueuedMessagesRemainInOrder() async throws {
        let inbox = MessageInbox(maximumQueuedMessages: 3, maximumQueuedBytes: 100)
        let first = ping(1)
        let second = ping(2)
        let third = ping(3)

        try inbox.yield(first, encodedByteCount: 10)
        try inbox.yield(second, encodedByteCount: 20)
        try inbox.yield(third, encodedByteCount: 30)

        let receivedFirst = try await inbox.next()
        XCTAssertEqual(receivedFirst, first)
        let fourth = ping(4)
        try inbox.yield(fourth, encodedByteCount: 40)
        let receivedSecond = try await inbox.next()
        let receivedThird = try await inbox.next()
        let receivedFourth = try await inbox.next()
        XCTAssertEqual(receivedSecond, second)
        XCTAssertEqual(receivedThird, third)
        XCTAssertEqual(receivedFourth, fourth)
    }

    func testCountLimitClosesAStalledInbox() async throws {
        let inbox = MessageInbox(maximumQueuedMessages: 2, maximumQueuedBytes: 100)
        let first = ping(1)
        let second = ping(2)

        try inbox.yield(first, encodedByteCount: 1)
        try inbox.yield(second, encodedByteCount: 1)
        XCTAssertThrowsError(try inbox.yield(ping(3), encodedByteCount: 1)) { error in
            XCTAssertEqual(error as? EkoCoreError, .resourceExhausted)
        }

        let receivedFirst = try await inbox.next()
        let receivedSecond = try await inbox.next()
        XCTAssertEqual(receivedFirst, first)
        XCTAssertEqual(receivedSecond, second)
        do {
            _ = try await inbox.next()
            XCTFail("Expected the terminal resource exhaustion error")
        } catch {
            XCTAssertEqual(error as? EkoCoreError, .resourceExhausted)
        }
    }

    func testByteLimitIsExactAndDequeuesReleaseBudget() async throws {
        let inbox = MessageInbox(maximumQueuedMessages: 4, maximumQueuedBytes: 5)
        let first = ping(1)
        let second = ping(2)
        let third = ping(3)

        try inbox.yield(first, encodedByteCount: 2)
        try inbox.yield(second, encodedByteCount: 3)
        let receivedFirst = try await inbox.next()
        XCTAssertEqual(receivedFirst, first)
        try inbox.yield(third, encodedByteCount: 2)

        let receivedSecond = try await inbox.next()
        let receivedThird = try await inbox.next()
        XCTAssertEqual(receivedSecond, second)
        XCTAssertEqual(receivedThird, third)
    }

    func testByteLimitRejectsOneByteOverBudget() async throws {
        let inbox = MessageInbox(maximumQueuedMessages: 4, maximumQueuedBytes: 5)
        try inbox.yield(ping(1), encodedByteCount: 5)

        XCTAssertThrowsError(try inbox.yield(ping(2), encodedByteCount: 1)) { error in
            XCTAssertEqual(error as? EkoCoreError, .resourceExhausted)
        }
    }

    func testCancelledWaiterDoesNotConsumeTheNextMessage() async throws {
        let inbox = MessageInbox(maximumQueuedMessages: 2, maximumQueuedBytes: 100)
        let waiting = Task { try await inbox.next() }
        await Task.yield()
        waiting.cancel()

        do {
            _ = try await waiting.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        let message = ping(1)
        try inbox.yield(message, encodedByteCount: 10)
        let received = try await inbox.next()
        XCTAssertEqual(received, message)
    }

    func testCleanFinishDrainsQueuedMessagesBeforeEOF() async throws {
        let inbox = MessageInbox(maximumQueuedMessages: 2, maximumQueuedBytes: 100)
        let message = ping(1)
        try inbox.yield(message, encodedByteCount: 10)

        inbox.finish(error: nil)

        let received = try await inbox.next()
        XCTAssertEqual(received, message)
        let eof = try await inbox.next()
        XCTAssertNil(eof)
    }

    func testCleanFinishResumesAWaitingReceiverWithEOF() async throws {
        let inbox = MessageInbox(maximumQueuedMessages: 2, maximumQueuedBytes: 100)
        let waiting = Task { try await inbox.next() }
        await Task.yield()

        inbox.finish(error: nil)

        let eof = try await waiting.value
        XCTAssertNil(eof)
    }

    func testProducerPausesAtHighWaterAndResumesAfterDrain() async throws {
        // Capacity 8: high-water at 4 queued messages, low-water at 2.
        let inbox = MessageInbox(maximumQueuedMessages: 8, maximumQueuedBytes: 10_000)
        let resumes = ResumeCounter()
        inbox.setOnResume { resumes.increment() }

        XCTAssertTrue(try inbox.yield(ping(1), encodedByteCount: 1))
        XCTAssertTrue(try inbox.yield(ping(2), encodedByteCount: 1))
        XCTAssertTrue(try inbox.yield(ping(3), encodedByteCount: 1))
        XCTAssertFalse(try inbox.yield(ping(4), encodedByteCount: 1), "fourth message crosses high water")

        _ = try await inbox.next()
        XCTAssertEqual(resumes.value, 0, "still above low water")
        _ = try await inbox.next()
        XCTAssertEqual(resumes.value, 1, "resume fires exactly once at low water")
        _ = try await inbox.next()
        XCTAssertEqual(resumes.value, 1, "no repeat resume while unpaused")

        XCTAssertTrue(try inbox.yield(ping(5), encodedByteCount: 1))
        XCTAssertTrue(try inbox.yield(ping(6), encodedByteCount: 1))
        XCTAssertFalse(try inbox.yield(ping(7), encodedByteCount: 1), "refilling to high water pauses again")
        _ = try await inbox.next()
        _ = try await inbox.next()
        _ = try await inbox.next()
        XCTAssertEqual(resumes.value, 2, "each pause earns one resume")
    }

    func testByteHighWaterAlsoPausesProducer() async throws {
        // Byte budget 100: high-water at 50 queued bytes, low-water at 25.
        let inbox = MessageInbox(maximumQueuedMessages: 100, maximumQueuedBytes: 100)
        let resumes = ResumeCounter()
        inbox.setOnResume { resumes.increment() }

        XCTAssertFalse(try inbox.yield(ping(1), encodedByteCount: 60), "single large frame crosses byte high water")
        _ = try await inbox.next()
        XCTAssertEqual(resumes.value, 1)
    }

    func testDirectWaiterHandoffNeverPauses() async throws {
        // Capacity 4 keeps the single-message queued fallback below high water
        // too, so the assertion cannot flake on waiter-registration timing.
        let inbox = MessageInbox(maximumQueuedMessages: 4, maximumQueuedBytes: 400)
        async let received = inbox.next()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(try inbox.yield(ping(1), encodedByteCount: 99), "handoff to a waiter bypasses the queue")
        let message = try await received
        XCTAssertEqual(message, ping(1))
    }

    private final class ResumeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    private func ping(_ value: Int64) -> WireMessage {
        .ping(PingMessage(
            pingID: "12345678-1234-4abc-8def-1234567890ab",
            phoneTime: value
        ))
    }
}
