import Foundation
import ServiceManagement

public enum LaunchAtLoginState: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval
    case outsideApplications
    case unavailable
    case failed(String)
}

@MainActor
public protocol LaunchAtLoginControlling: AnyObject {
    func state() -> LaunchAtLoginState
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginState
    func openApprovalSettings()
}

@MainActor
public final class LaunchAtLoginService: LaunchAtLoginControlling {
    private let service: SMAppService
    private let bundleURL: URL

    public init(service: SMAppService = .mainApp, bundleURL: URL = Bundle.main.bundleURL) {
        self.service = service
        self.bundleURL = bundleURL
    }

    public func state() -> LaunchAtLoginState {
        guard isInApplications else { return .outsideApplications }
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .disabled
        case .notFound: return .unavailable
        @unknown default: return .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) -> LaunchAtLoginState {
        guard isInApplications else { return .outsideApplications }
        do {
            if enabled {
                if service.status != .enabled { try service.register() }
            } else if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
            }
            return state()
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var isInApplications: Bool {
        bundleURL.standardizedFileURL.path == "/Applications/Eko.app"
            || bundleURL.standardizedFileURL.path.hasPrefix("/Applications/")
    }
}
