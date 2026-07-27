import Foundation

public enum FrameType: UInt8, Sendable {
    case json = 0x01
}

public enum DecodedFrame: Equatable, Sendable {
    case json(Data)
}

enum FrameLayout {
    static let lengthPrefixByteCount = 4
    static let typeByteCount = 1
    static let headerByteCount = lengthPrefixByteCount + typeByteCount
}

public struct FrameDecoder: Sendable {
    private var storage = Data()
    private var offset = 0

    public init() {}

    public mutating func append(_ bytes: Data) throws -> [DecodedFrame] {
        storage.append(bytes)
        var frames: [DecodedFrame] = []

        while storage.count - offset >= FrameLayout.lengthPrefixByteCount {
            let length = Int(storage.uint32(at: offset))
            guard length > 0 else { throw EkoCoreError.protocolViolation("frame length is zero") }
            guard length <= ProtocolLimits.maximumFrameLength else {
                throw EkoCoreError.frameTooLarge
            }
            guard storage.count - offset >= FrameLayout.lengthPrefixByteCount + length else { break }

            let type = storage[offset + FrameLayout.lengthPrefixByteCount]
            let payloadStart = offset + FrameLayout.headerByteCount
            let payloadEnd = offset + FrameLayout.lengthPrefixByteCount + length
            let payload = Data(storage[payloadStart..<payloadEnd])
            if type == FrameType.json.rawValue {
                frames.append(.json(payload))
            }
            offset = payloadEnd
        }

        if offset == storage.count {
            storage.removeAll(keepingCapacity: true)
            offset = 0
        } else if offset > 65_536 {
            storage.removeSubrange(0..<offset)
            offset = 0
        }
        return frames
    }

    public mutating func finish() throws {
        let remaining = storage.count - offset
        guard remaining > 0 else { return }
        guard remaining >= FrameLayout.lengthPrefixByteCount else {
            throw EkoCoreError.protocolViolation("connection ended during frame prefix")
        }
        let length = Int(storage.uint32(at: offset))
        guard length > 0 else { throw EkoCoreError.protocolViolation("frame length is zero") }
        guard length <= ProtocolLimits.maximumFrameLength else {
            throw EkoCoreError.frameTooLarge
        }
        guard remaining >= FrameLayout.lengthPrefixByteCount + length else {
            throw EkoCoreError.protocolViolation("connection ended during frame body")
        }
    }

    public var bufferedByteCount: Int { storage.count - offset }
}

public enum FrameEncoder {
    public static func encode(type: FrameType, payload: Data) throws -> Data {
        let length = payload.count + FrameLayout.typeByteCount
        guard length <= ProtocolLimits.maximumFrameLength else {
            throw EkoCoreError.frameTooLarge
        }
        var frame = Data(capacity: payload.count + FrameLayout.headerByteCount)
        frame.appendUInt32(UInt32(length))
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    public static func encode(_ message: WireMessage) throws -> Data {
        try encode(type: .json, payload: ProtocolCodec.encode(message))
    }
}
