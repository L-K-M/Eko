import Foundation
import XCTest
@testable import EkoCore

final class DiscoveryConstantsTests: XCTestCase {
    func testBLEServiceUUIDMatchesSharedDiscoveryVector() async throws {
        let data = try Data(contentsOf: protocolVectorURL("discovery.json"))
        let vector = try JSONDecoder().decode(DiscoveryVector.self, from: data)
        let serviceUUID = await MainActor.run {
            BLEAdvertiser.serviceUUID.uuidString.lowercased()
        }

        XCTAssertEqual(vector.format, "eko-discovery-v1")
        XCTAssertEqual(serviceUUID, vector.bleServiceUUID)
    }
}

private struct DiscoveryVector: Decodable {
    let format: String
    let bleServiceUUID: String

    private enum CodingKeys: String, CodingKey {
        case format
        case bleServiceUUID = "ble_service_uuid"
    }
}
