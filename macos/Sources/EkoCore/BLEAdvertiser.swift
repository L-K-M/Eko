import CoreBluetooth
import Foundation

public enum BLEAdvertisingState: Equatable, Sendable {
    case stopped
    case starting
    case advertising
    case poweredOff
    case unauthorized
    case unsupported
    case failed(String)
}

@MainActor
public protocol BLEAdvertising: AnyObject {
    func start()
    func stop()
}

@MainActor
public final class BLEAdvertiser: NSObject, BLEAdvertising, CBPeripheralManagerDelegate {
    public static let serviceUUID = CBUUID(string: "7A65D130-63A5-4D85-9A45-4D9E6D90E001")
    public typealias StateHandler = @MainActor (BLEAdvertisingState) -> Void

    private let stateHandler: StateHandler
    private var manager: CBPeripheralManager?
    private var shouldAdvertise = false
    private var serviceAdded = false

    public init(stateHandler: @escaping StateHandler = { _ in }) {
        self.stateHandler = stateHandler
        super.init()
    }

    public func start() {
        shouldAdvertise = true
        stateHandler(.starting)
        if manager == nil {
            manager = CBPeripheralManager(
                delegate: self,
                queue: .main,
                options: [CBPeripheralManagerOptionShowPowerAlertKey: false]
            )
        } else {
            updateAdvertisingForState()
        }
    }

    public func stop() {
        shouldAdvertise = false
        manager?.stopAdvertising()
        stateHandler(.stopped)
    }

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        updateAdvertisingForState()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard service.uuid == Self.serviceUUID else { return }
        if let error {
            stateHandler(.failed(error.localizedDescription))
            return
        }
        serviceAdded = true
        beginAdvertisingIfReady()
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            stateHandler(.failed(error.localizedDescription))
        } else {
            stateHandler(.advertising)
        }
    }

    private func updateAdvertisingForState() {
        guard let manager else { return }
        switch manager.state {
        case .poweredOn:
            if !serviceAdded {
                let service = CBMutableService(type: Self.serviceUUID, primary: true)
                service.characteristics = []
                manager.add(service)
            } else {
                beginAdvertisingIfReady()
            }
        case .poweredOff:
            manager.stopAdvertising()
            stateHandler(.poweredOff)
        case .unauthorized:
            stateHandler(.unauthorized)
        case .unsupported:
            stateHandler(.unsupported)
        case .resetting, .unknown:
            stateHandler(.starting)
        @unknown default:
            stateHandler(.unsupported)
        }
    }

    private func beginAdvertisingIfReady() {
        guard shouldAdvertise, serviceAdded, let manager, manager.state == .poweredOn,
              !manager.isAdvertising else { return }
        manager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
            CBAdvertisementDataLocalNameKey: "Eko",
        ])
    }
}
