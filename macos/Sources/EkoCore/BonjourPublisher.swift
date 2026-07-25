import Foundation

public enum BonjourPublicationState: Equatable, Sendable {
    case stopped
    case publishing
    case published
    case policyDenied
    case failed(String)
}

@MainActor
public protocol BonjourPublishing: AnyObject {
    func publish(port: UInt16, fingerprint: String)
    func stop()
}

@MainActor
public final class BonjourPublisher: NSObject, BonjourPublishing, NetServiceDelegate {
    public typealias StateHandler = @MainActor (BonjourPublicationState) -> Void

    private let stateHandler: StateHandler
    private var service: NetService?

    public init(stateHandler: @escaping StateHandler = { _ in }) {
        self.stateHandler = stateHandler
        super.init()
    }

    public func publish(port: UInt16, fingerprint: String) {
        stop()
        let computerName = Host.current().localizedName ?? "Mac"
        let service = NetService(
            domain: "local.",
            type: "_eko._tcp.",
            name: "Eko on \(computerName)",
            port: Int32(port)
        )
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "fp": Data(fingerprint.utf8),
            "proto": Data("1".utf8),
        ]))
        self.service = service
        stateHandler(.publishing)
        service.publish()
    }

    public func stop() {
        service?.stop()
        service?.delegate = nil
        service = nil
        stateHandler(.stopped)
    }

    public func netServiceDidPublish(_ sender: NetService) {
        guard sender === service else { return }
        stateHandler(.published)
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        if code == -65_570 {
            stateHandler(.policyDenied)
        } else {
            stateHandler(.failed("DNS-SD error \(code)"))
        }
    }

    public func netServiceDidStop(_ sender: NetService) {
        guard sender === service else { return }
        stateHandler(.stopped)
    }
}
