import Foundation
import XCTest
@testable import EkoCore

final class SessionSemanticsTests: XCTestCase {
    func testBacklogRequiresCompleteGapEventAndSnapshotCoverage() throws {
        var state = SessionStateMachine(cursor: 3, generation: "g", negotiatedCapabilities: [])
        XCTAssertNil(try state.accept(.backlogStart(BacklogStartMessage(
            syncID: testSyncID,
            fromSequence: 5,
            replayToSequence: 6,
            eventCount: 2
        ))))
        XCTAssertEqual(try state.accept(.backlogGap(BacklogGapMessage(
            syncID: testSyncID,
            fromSequence: 4,
            toSequence: 4,
            reason: "retention_count"
        ))), .ingestGap(BacklogGapMessage(
            syncID: testSyncID,
            fromSequence: 4,
            toSequence: 4,
            reason: "retention_count"
        )))
        _ = try state.accept(.event(testEvent(sequence: 5, key: "a", replayed: true)))
        _ = try state.accept(.event(testEvent(sequence: 6, key: "b", replayed: true)))
        _ = try state.accept(.activeChunk(ActiveChunkMessage(
            syncID: testSyncID,
            index: 0,
            final: true,
            active: [ActiveEntry(key: "b", contentHash: String(repeating: "a", count: 64), stateSequence: 6)]
        )))
        let action = try state.accept(.backlogEnd(BacklogEndMessage(syncID: testSyncID, stateSequence: 6)))
        guard case .backlogCompleted(let completion) = action else {
            return XCTFail("Expected backlog completion")
        }
        XCTAssertEqual(completion.stateSequence, 6)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.processedThrough, 6)
    }

    func testBacklogEndBeforeCoverageIsRejected() throws {
        var state = SessionStateMachine(cursor: 0, generation: "g", negotiatedCapabilities: [])
        _ = try state.accept(.backlogStart(BacklogStartMessage(
            syncID: testSyncID,
            fromSequence: 1,
            replayToSequence: 1,
            eventCount: 1
        )))
        XCTAssertThrowsError(try state.accept(.backlogEnd(BacklogEndMessage(syncID: testSyncID, stateSequence: 1))))
    }

    func testActiveSnapshotRejectsDuplicateKeysAcrossChunks() throws {
        var state = SessionStateMachine(cursor: 1, generation: testGenerationA, negotiatedCapabilities: [])
        _ = try state.accept(.backlogStart(BacklogStartMessage(
            syncID: testSyncID,
            fromSequence: 2,
            replayToSequence: 1,
            eventCount: 0
        )))
        let entry = ActiveEntry(
            key: "duplicate",
            contentHash: String(repeating: "a", count: 64),
            stateSequence: 1
        )
        _ = try state.accept(.activeChunk(ActiveChunkMessage(
            syncID: testSyncID,
            index: 0,
            final: false,
            active: [entry]
        )))
        XCTAssertThrowsError(try state.accept(.activeChunk(ActiveChunkMessage(
            syncID: testSyncID,
            index: 1,
            final: true,
            active: [entry]
        ))))
    }

    func testActiveSnapshotAcrossManyChunksHasNoTotalCap() throws {
        var state = SessionStateMachine(cursor: 1, generation: testGenerationA, negotiatedCapabilities: [])
        _ = try state.accept(.backlogStart(BacklogStartMessage(
            syncID: testSyncID,
            fromSequence: 2,
            replayToSequence: 1,
            eventCount: 0
        )))
        let chunkCount = 3
        let perChunk = 4_096
        for index in 0..<chunkCount {
            let entries = (0..<perChunk).map {
                ActiveEntry(
                    key: "chunk-\(index)-key-\($0)",
                    contentHash: String(repeating: "a", count: 64),
                    stateSequence: 1
                )
            }
            _ = try state.accept(.activeChunk(ActiveChunkMessage(
                syncID: testSyncID,
                index: Int64(index),
                final: index == chunkCount - 1,
                active: entries
            )))
        }
        let action = try state.accept(.backlogEnd(BacklogEndMessage(syncID: testSyncID, stateSequence: 1)))
        guard case .backlogCompleted(let completion) = action else {
            return XCTFail("Expected backlog completion")
        }
        XCTAssertEqual(completion.activeEntries.count, chunkCount * perChunk)
        XCTAssertEqual(state.phase, .live)
    }

    func testLiveSequenceMustBeContiguous() throws {
        var state = try liveState(cursor: 4)
        XCTAssertThrowsError(try state.accept(.event(testEvent(sequence: 6))))
        XCTAssertNoThrow(try state.accept(.event(testEvent(sequence: 5))))
    }

    func testUnknownMessageRequiresNegotiatedCapability() throws {
        var strict = try liveState(cursor: 0)
        XCTAssertThrowsError(try strict.accept(.unknown(type: "future", payload: Data(#"{"type":"future"}"#.utf8))))

        var extensible = SessionStateMachine(cursor: 0, generation: "g", negotiatedCapabilities: ["ext_types"])
        _ = try makeLive(&extensible)
        XCTAssertEqual(
            try extensible.accept(.unknown(type: "future", payload: Data(#"{"type":"future"}"#.utf8))),
            .ignoreExtension("future")
        )
    }

    func testHigherEpochSupersedesAndEqualEpochLoses() async throws {
        let registry = SessionEpochRegistry()
        let first = UUID()
        let second = UUID()
        let initial = try await registry.admit(deviceID: "device", epoch: 10, connectionID: first)
        XCTAssertNil(initial.displacedConnectionID)
        let replacement = try await registry.admit(deviceID: "device", epoch: 11, connectionID: second)
        XCTAssertEqual(replacement.displacedConnectionID, first)
        await XCTAssertThrowsErrorAsync {
            _ = try await registry.admit(deviceID: "device", epoch: 11, connectionID: UUID())
        }
    }

    func testAckAccumulatorDoesNotSendUntilCommitIsReported() async throws {
        let transport = RecordingTransport()
        let accumulator = AckAccumulator(transport: transport, clock: SuspendedClock())
        let beforeCommit = await transport.sentMessages()
        XCTAssertTrue(beforeCommit.isEmpty)
        try await accumulator.committed(sequence: 1)
        let beforeFlush = await transport.sentMessages()
        XCTAssertTrue(beforeFlush.isEmpty)
        try await accumulator.flush()
        let afterFlush = await transport.sentMessages()
        XCTAssertEqual(afterFlush, [.ack(AckMessage(sequence: 1))])
    }

    func testFetchResponsesAreBoundToOneOutstandingRequest() throws {
        var state = try liveState(cursor: 4)
        let requestID = "12345678-1234-4abc-8def-1234567890ab"
        try state.beginFetch(FetchMessage(requestID: requestID, keys: ["a", "b"]))
        XCTAssertThrowsError(try state.beginFetch(FetchMessage(
            requestID: "23456789-2345-4bcd-9ef0-234567890abc",
            keys: ["c"]
        )))
        _ = try state.accept(.fetchMissing(FetchMissingMessage(
            requestID: requestID,
            key: "a",
            stateSequence: 4
        )))
        XCTAssertTrue(state.hasOutstandingFetch)
        _ = try state.accept(.fetchMissing(FetchMissingMessage(
            requestID: requestID,
            key: "b",
            stateSequence: 4
        )))
        XCTAssertFalse(state.hasOutstandingFetch)
    }

    private func liveState(cursor: Int64) throws -> SessionStateMachine {
        var state = SessionStateMachine(cursor: cursor, generation: "g", negotiatedCapabilities: [])
        try makeLive(&state)
        return state
    }

    @discardableResult
    private func makeLive(_ state: inout SessionStateMachine) throws -> SessionAction? {
        _ = try state.accept(.backlogStart(BacklogStartMessage(
            syncID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            fromSequence: state.processedThrough + 1,
            replayToSequence: state.processedThrough,
            eventCount: 0
        )))
        _ = try state.accept(.activeChunk(ActiveChunkMessage(
            syncID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            index: 0,
            final: true,
            active: []
        )))
        return try state.accept(.backlogEnd(BacklogEndMessage(
            syncID: "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff",
            stateSequence: state.processedThrough
        )))
    }
}

private struct SuspendedClock: EkoClock {
    func now() -> Date { Date() }
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: .seconds(3_600))
    }
}

private final class RecordingTransport: SessionTransport, @unchecked Sendable {
    let id = UUID()
    let remoteEndpointDescription = "test"
    private let storage = MessageStorage()

    func receive() async throws -> WireMessage? { nil }
    func send(_ message: WireMessage) async throws { await storage.append(message) }
    func close() async {}
    func sentMessages() async -> [WireMessage] { await storage.values }
}

private actor MessageStorage {
    private(set) var values: [WireMessage] = []
    func append(_ message: WireMessage) { values.append(message) }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
