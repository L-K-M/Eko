import Foundation
import XCTest
@testable import EkoCore

final class DiagnosticsRecorderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_753_351_200)
    private let identityFingerprint = "local-identity-fingerprint-canary"

    func testDefaultExportRemovesSensitiveCanaries() async throws {
        let fixture = try makeStore()
        let recorder = DiagnosticsRecorder(clock: FixedClock(date: now))
        let exportURL = temporaryExportURL()
        defer { try? FileManager.default.removeItem(at: exportURL) }

        let canaries = sensitiveCanaries(fixture)
        await recorder.record(
            .error,
            category: fixture.hello.deviceID,
            message: canaries.joined(separator: " | ")
        )
        try await recorder.export(
            to: exportURL,
            store: fixture.store,
            identityFingerprint: identityFingerprint,
            appVersion: "1.2.3",
            includeNotificationContent: false
        )

        let exported = try String(contentsOf: exportURL, encoding: .utf8)
        for canary in canaries {
            XCTAssertFalse(exported.localizedCaseInsensitiveContains(canary), "Leaked diagnostic canary: \(canary)")
        }
        XCTAssertTrue(exported.contains("<redacted>"))
        let payload = try decodeExport(exportURL)
        XCTAssertEqual(payload.events.first?.category, "redacted")
        XCTAssertEqual(payload.notifications.first?.title, "<redacted>")
        XCTAssertEqual(payload.notifications.first?.body, "<redacted>")
        XCTAssertEqual(payload.notifications.first?.titleCharacterCount, "Sender".count)
        XCTAssertEqual(payload.notifications.first?.bodyCharacterCount, "Verification code 123456".count)
    }

    func testPseudonymsAreStableWithinOneExportAndRotateAcrossExports() async throws {
        let fixture = try makeStore()
        let recorder = DiagnosticsRecorder(clock: FixedClock(date: now))
        let firstURL = temporaryExportURL()
        let secondURL = temporaryExportURL()
        let contentURL = temporaryExportURL()
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
            try? FileManager.default.removeItem(at: contentURL)
        }

        await recorder.record(.info, category: "session", message: "event digest canary")

        try await recorder.export(
            to: firstURL,
            store: fixture.store,
            identityFingerprint: identityFingerprint,
            appVersion: "1.2.3",
            includeNotificationContent: false
        )
        try await recorder.export(
            to: secondURL,
            store: fixture.store,
            identityFingerprint: identityFingerprint,
            appVersion: "1.2.3",
            includeNotificationContent: false
        )
        try await recorder.export(
            to: contentURL,
            store: fixture.store,
            identityFingerprint: identityFingerprint,
            appVersion: "1.2.3",
            includeNotificationContent: true
        )

        let first = try decodeExport(firstURL)
        let second = try decodeExport(secondURL)
        let firstDevice = try XCTUnwrap(first.devices.first)
        let secondDevice = try XCTUnwrap(second.devices.first)
        let firstNotification = try XCTUnwrap(first.notifications.first)
        let secondNotification = try XCTUnwrap(second.notifications.first)
        XCTAssertEqual(firstDevice.idAlias, firstNotification.deviceAlias)
        XCTAssertEqual(secondDevice.idAlias, secondNotification.deviceAlias)
        XCTAssertNotEqual(firstDevice.idAlias, secondDevice.idAlias)
        XCTAssertNotEqual(firstDevice.name, secondDevice.name)
        XCTAssertNotEqual(firstDevice.certificateAlias, secondDevice.certificateAlias)
        XCTAssertNotEqual(first.identityAlias, second.identityAlias)
        XCTAssertNotEqual(firstNotification.appAlias, secondNotification.appAlias)
        XCTAssertEqual(first.events.first?.category, "session")
        XCTAssertEqual(first.events.first?.message, "<redacted>")
        XCTAssertNotEqual(first.events.first?.messageDigest, second.events.first?.messageDigest)

        let content = try decodeExport(contentURL)
        let includedNotification = try XCTUnwrap(content.notifications.first)
        XCTAssertTrue(content.notificationContentIncluded)
        XCTAssertEqual(includedNotification.title, "Sender")
        XCTAssertEqual(includedNotification.body, "Verification code 123456")
        let contentJSON = try String(contentsOf: contentURL, encoding: .utf8)
        for canary in metadataCanaries(fixture) {
            XCTAssertFalse(contentJSON.localizedCaseInsensitiveContains(canary), "Leaked metadata canary: \(canary)")
        }
    }

    private func makeStore() throws -> Fixture {
        let certificate = Data((0..<128).map { UInt8($0 & 0xff) })
        let hello = testHello(certificateDER: certificate)
        let endpoint = "127.0.0.1:48808"
        let databasePath = try temporaryDatabasePath()
        let databaseDirectory = URL(fileURLWithPath: databasePath).deletingLastPathComponent()
        addTeardownBlock { try? FileManager.default.removeItem(at: databaseDirectory) }
        let store = try EkoStore(path: databasePath, clock: FixedClock(date: now))
        _ = try store.confirmPairing(
            hello: hello,
            certificateDER: certificate,
            initialCursor: 0,
            negotiatedProtocol: 1,
            endpoint: endpoint
        )
        _ = try store.ingestEvent(
            deviceID: hello.deviceID,
            generation: try XCTUnwrap(hello.outboxGeneration),
            event: testEvent(sequence: 1)
        )
        return Fixture(store: store, hello: hello, certificate: certificate, endpoint: endpoint)
    }

    private func sensitiveCanaries(_ fixture: Fixture) -> [String] {
        metadataCanaries(fixture) + [
            "Sender",
            "Verification code 123456",
            "event-only-secret-canary",
        ]
    }

    private func metadataCanaries(_ fixture: Fixture) -> [String] {
        [
            identityFingerprint,
            fixture.hello.deviceID,
            String(fixture.hello.deviceID.prefix(8)),
            String(fixture.hello.deviceID.prefix(12)),
            fixture.hello.deviceName,
            fixture.hello.outboxGeneration ?? "missing-generation",
            fixture.certificate.base64EncodedString(),
            fixture.certificate.hexLowercased,
            fixture.certificate.hexUppercased,
            fixture.endpoint,
            "127.0.0.1",
            "com.example.messages",
            "notification-key",
        ]
    }

    private func decodeExport(_ url: URL) throws -> DiagnosticsExport {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DiagnosticsExport.self, from: Data(contentsOf: url))
    }

    private func temporaryExportURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eko-diagnostics-\(UUID().uuidString).json")
    }
}

private struct Fixture {
    let store: EkoStore
    let hello: HelloMessage
    let certificate: Data
    let endpoint: String
}
