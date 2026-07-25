import XCTest
@testable import EkoCore

final class ProtocolCodecTests: XCTestCase {
    func testSharedPairingScenarioFramesMatchWireModels() throws {
        let data = try Data(contentsOf: protocolVectorURL("scenarios/pairing-retry.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try XCTUnwrap(root["steps"] as? [[String: Any]])
        var decodedTypes: [String] = []

        for step in steps {
            guard let frame = step["frame"] as? [String: Any] else { continue }
            let payload = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            decodedTypes.append(try ProtocolCodec.decode(payload).type)
        }

        XCTAssertTrue(decodedTypes.contains("hello"))
        XCTAssertTrue(decodedTypes.contains("pair_request"))
        XCTAssertTrue(decodedTypes.contains("pair_commit"))
        XCTAssertTrue(decodedTypes.contains("pair_reveal"))
        XCTAssertTrue(decodedTypes.contains("pair_result"))
        XCTAssertTrue(decodedTypes.contains("welcome"))
    }

    func testSharedResumeEventsDecodeTheirNormativeShapes() throws {
        let data = try Data(contentsOf: protocolVectorURL("scenarios/resume.json"))
        let root = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let steps = try XCTUnwrap(root["steps"] as? [[String: Any]])
        let eventFrames = steps.compactMap { $0["frame"] as? [String: Any] }.filter { $0["type"] as? String == "event" }

        let events = try eventFrames.map { frame -> EventMessage in
            let payload = try JSONSerialization.data(withJSONObject: frame, options: [.sortedKeys])
            guard case .event(let event) = try ProtocolCodec.decode(payload) else {
                throw EkoCoreError.invalidData("expected event")
            }
            return event
        }

        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(events[0].syncID, testSyncID)
        XCTAssertEqual(events[1].removeReason, RemoveReason(code: 2, reconciled: false))
        XCTAssertNil(events[2].syncID)
    }

    func testSharedMalformedSchemaCasesAreRejected() throws {
        let vectors = try JSONDecoder().decode(
            MalformedVectors.self,
            from: Data(contentsOf: protocolVectorURL("malformed-frames.json"))
        )
        let schemaCases: Set<String> = [
            "fractional-integer-field",
            "exponent-integer-lexical-form",
            "negative-sequence",
            "zero-event-sequence",
            "integer-over-uint53",
            "invalid-hello-mode",
            "uppercase-certificate-fingerprint",
            "pair-reveal-short-nonce",
            "truncated-content-hash",
            "fetch-event-illegally-has-seq",
            "replayed-event-missing-sync-id",
            "live-event-illegally-has-sync-id",
        ]

        var tested = 0
        for vector in vectors.vectors where schemaCases.contains(vector.id) {
            let payload = try XCTUnwrap(vector.input.payloadUTF8)
            XCTAssertThrowsError(try ProtocolCodec.decode(Data(payload.utf8)), vector.id)
            tested += 1
        }
        XCTAssertEqual(tested, schemaCases.count)
    }

    func testEncodingPreservesRequiredNullMembers() throws {
        let event = testEvent(sequence: 1, event: .removed)
        let data = try ProtocolCodec.encode(.event(event))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let app = try XCTUnwrap(object["app"] as? [String: Any])

        XCTAssertTrue(object["h"] is NSNull)
        XCTAssertTrue(app.keys.contains("category"))
        XCTAssertNotNil(object["remove_reason"])

        let postedData = try ProtocolCodec.encode(.event(testEvent(sequence: 2)))
        let posted = try XCTUnwrap(try JSONSerialization.jsonObject(with: postedData) as? [String: Any])
        let content = try XCTUnwrap(posted["n"] as? [String: Any])
        XCTAssertTrue(content["big_text"] is NSNull)
        XCTAssertTrue(content["messages"] is NSNull)
        XCTAssertTrue(content["group_key"] is NSNull)
    }
}

private struct MalformedVectors: Decodable {
    let vectors: [Vector]

    struct Vector: Decodable {
        let id: String
        let input: Input
    }

    struct Input: Decodable {
        let payloadUTF8: String?

        enum CodingKeys: String, CodingKey {
            case payloadUTF8 = "payload_utf8"
        }
    }
}
