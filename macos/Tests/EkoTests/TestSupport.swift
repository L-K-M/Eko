import EkoCore
import Foundation

let testGenerationA = "11111111-2222-4333-8444-555555555555"
let testGenerationB = "66666666-7777-4888-9999-aaaaaaaaaaaa"
let testSyncID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

struct FixedClock: EkoClock {
    let date: Date

    func now() -> Date { date }
    func sleep(for duration: Duration) async throws {}
}

final class MutableClock: EkoClock, @unchecked Sendable {
    var date: Date

    init(date: Date) { self.date = date }

    func now() -> Date { date }
    func sleep(for duration: Duration) async throws {}
}

func temporaryDatabasePath(_ name: String = UUID().uuidString) throws -> String {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("EkoTests", isDirectory: true)
        .appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("test.sqlite").path
}

func testHello(
    certificateDER: Data,
    generation: String = testGenerationA,
    epoch: Int64 = 1,
    mode: ProtocolMode = .normal,
    attemptID: String? = nil
) -> HelloMessage {
    HelloMessage(
        mode: mode,
        protoMin: 1,
        protoMax: 1,
        deviceID: EkoCrypto.fingerprint(of: certificateDER),
        deviceName: "Test Phone",
        os: "android",
        osVersion: 35,
        capabilities: ["notif", "dismiss", "otp_context"],
        outboxGeneration: generation,
        connectionEpoch: epoch,
        phoneTime: 1_753_351_200_000,
        attemptID: attemptID
    )
}

func testEvent(
    sequence: Int64,
    key: String = "notification-key",
    text: String = "Verification code 123456",
    contentHash: String = String(repeating: "a", count: 64),
    replayed: Bool = false,
    event: EventKind = .posted
) -> EventMessage {
    if event == .removed {
        return EventMessage(
            syncID: replayed ? testSyncID : nil,
            sequence: sequence,
            event: .removed,
            key: key,
            postedAt: 1_753_351_199_000,
            user: 0,
            app: EventApp(package: "com.example.messages", label: "Messages", category: "msg"),
            dnd: DNDState(),
            flags: EventFlags(replayed: replayed),
            truncatedFields: [],
            removeReason: RemoveReason(code: 2, reconciled: false)
        )
    }
    return EventMessage(
        syncID: replayed ? testSyncID : nil,
        sequence: sequence,
        event: event,
        key: key,
        postedAt: 1_753_351_199_000,
        user: 0,
        contentHash: contentHash,
        app: EventApp(package: "com.example.messages", label: "Messages", category: "msg"),
        notification: NotificationContent(title: "Sender", text: text),
        dnd: DNDState(),
        flags: EventFlags(replayed: replayed),
        truncatedFields: []
    )
}

func testFetchEvent(
    stateSequence: Int64,
    key: String = "notification-key",
    text: String = "Verification code 123456",
    contentHash: String = String(repeating: "a", count: 64),
    requestID: String = "12345678-1234-4abc-8def-1234567890ab"
) -> EventMessage {
    EventMessage(
        stateSequence: stateSequence,
        requestID: requestID,
        event: .posted,
        key: key,
        postedAt: 1_753_351_199_000,
        user: 0,
        contentHash: contentHash,
        app: EventApp(package: "com.example.messages", label: "Messages", category: "msg"),
        notification: NotificationContent(title: "Sender", text: text),
        dnd: DNDState(),
        flags: EventFlags(replayed: false, reconciled: true),
        truncatedFields: []
    )
}

func protocolVectorURL(_ relativePath: String) -> URL {
    repoArtifactURL(directory: "protocol/test-vectors", relativePath: relativePath)
}

func otpCorpusURL(_ relativePath: String) -> URL {
    repoArtifactURL(directory: "protocol/otp-corpus", relativePath: relativePath)
}

private func repoArtifactURL(directory: String, relativePath: String) -> URL {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { root.deleteLastPathComponent() }
    let sourceCandidate = root.appendingPathComponent(directory).appendingPathComponent(relativePath)
    if FileManager.default.fileExists(atPath: sourceCandidate.path) { return sourceCandidate }

    let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let workingCandidates = [workingDirectory, workingDirectory.deletingLastPathComponent()]
    for candidate in workingCandidates {
        let url = candidate.appendingPathComponent(directory).appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    return sourceCandidate
}
