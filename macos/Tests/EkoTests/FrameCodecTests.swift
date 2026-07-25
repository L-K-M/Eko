import XCTest
@testable import EkoCore

final class FrameCodecTests: XCTestCase {
    func testFragmentedJSONFrameRoundTrips() throws {
        let certificate = Data(repeating: 0x42, count: 96)
        let message = WireMessage.hello(testHello(certificateDER: certificate))
        let encoded = try FrameEncoder.encode(message)
        var decoder = FrameDecoder()
        var frames: [DecodedFrame] = []

        for byte in encoded {
            frames.append(contentsOf: try decoder.append(Data([byte])))
        }

        XCTAssertEqual(frames.count, 1)
        guard case .json(let payload) = frames[0] else {
            return XCTFail("Expected a JSON frame")
        }
        XCTAssertEqual(try ProtocolCodec.decode(payload), message)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testMultipleFramesInOneRead() throws {
        let pingID = "12345678-1234-4abc-8def-1234567890ab"
        let first = try FrameEncoder.encode(.ping(PingMessage(pingID: pingID, phoneTime: 100)))
        let second = try FrameEncoder.encode(.pong(PongMessage(pingID: pingID, phoneTime: 100, macTime: 101)))
        var decoder = FrameDecoder()
        let frames = try decoder.append(first + second)
        XCTAssertEqual(frames.count, 2)
    }

    func testZeroLengthIsRejectedBeforeAllocation() {
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(Data([0, 0, 0, 0])))
    }

    func testOversizedLengthIsRejectedBeforeAllocation() {
        var prefix = Data()
        prefix.appendUInt32(UInt32(ProtocolLimits.maximumFrameLength + 1))
        var decoder = FrameDecoder()
        XCTAssertThrowsError(try decoder.append(prefix))
    }

    func testUnknownFrameTypeIsSkippedByDeclaredLength() throws {
        var unknown = Data([0, 0, 0, 4, 0x7f, 1, 2, 3])
        unknown.append(try FrameEncoder.encode(.ping(PingMessage(
            pingID: "12345678-1234-4abc-8def-1234567890ab",
            phoneTime: 100
        ))))
        var decoder = FrameDecoder()
        let frames = try decoder.append(unknown)
        XCTAssertEqual(frames.count, 1)
    }

    func testDuplicateJSONKeyIsRejected() {
        let payload = Data(#"{"type":"ping","type":"pong"}"#.utf8)
        XCTAssertThrowsError(try ProtocolCodec.decode(payload))
    }

    func testInvalidUTF8IsRejected() {
        XCTAssertThrowsError(try ProtocolCodec.decode(Data([0xff, 0xfe])))
    }

    func testSharedFramingVectors() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let vectors = try decoder.decode(
            FramingVectors.self,
            from: Data(contentsOf: protocolVectorURL("framing.json"))
        )
        for vector in vectors.vectors {
            guard let wireHex = vector.wireHex, let wire = Data(hex: wireHex) else { continue }
            var frameDecoder = FrameDecoder()
            let frames = try frameDecoder.append(wire)
            if vector.expect == "skip" {
                XCTAssertTrue(frames.isEmpty, vector.id)
            } else {
                guard case .json(let payload) = try XCTUnwrap(frames.first) else {
                    return XCTFail("Expected JSON for \(vector.id)")
                }
                XCTAssertNoThrow(try ProtocolCodec.decode(payload), vector.id)
            }
        }
    }

    func testMaximumLegalUnknownFrameIsSkipped() throws {
        var wire = Data()
        wire.appendUInt32(UInt32(ProtocolLimits.maximumFrameLength))
        wire.append(0x7f)
        wire.append(Data(repeating: 0, count: ProtocolLimits.maximumFrameLength - 1))
        var decoder = FrameDecoder()
        XCTAssertTrue(try decoder.append(wire).isEmpty)
        XCTAssertEqual(decoder.bufferedByteCount, 0)
    }

    func testIncompleteFrameIsRejectedAtEOF() throws {
        var decoder = FrameDecoder()
        _ = try decoder.append(Data([0, 0]))
        XCTAssertThrowsError(try decoder.finish())

        var bodyDecoder = FrameDecoder()
        _ = try bodyDecoder.append(Data([0, 0, 0, 5, 0x01, 0x7b, 0x7d]))
        XCTAssertThrowsError(try bodyDecoder.finish())
    }
}

private struct FramingVectors: Decodable {
    let vectors: [Vector]

    struct Vector: Decodable {
        let id: String
        let wireHex: String?
        let expect: String
    }
}
