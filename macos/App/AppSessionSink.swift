import EkoCore
import Foundation

final class AppSessionSink: SessionEventSink, @unchecked Sendable {
    private weak var model: AppModel?
    private let store: EkoStore
    private let notifications: NotificationCoordinator
    private let diagnostics: DiagnosticsRecorder

    init(model: AppModel, store: EkoStore, notifications: NotificationCoordinator, diagnostics: DiagnosticsRecorder) {
        self.model = model
        self.store = store
        self.notifications = notifications
        self.diagnostics = diagnostics
    }

    func connectionStateChanged(deviceID: String, state: DeviceConnectionState) async {
        await model?.setConnectionState(deviceID: deviceID, state: state)
        await diagnostics.record(.info, category: "session", message: "\(String(deviceID.prefix(12))) state \(String(describing: state))")
    }

    func sessionNegotiated(_ session: SessionDiagnostics) async {
        await diagnostics.record(
            .info,
            category: "protocol",
            message: "\(String(session.deviceID.prefix(12))) proto \(session.protocolVersion), generation \(session.generation), epoch \(session.connectionEpoch), clock skew \(session.clockSkewMilliseconds) ms"
        )
    }

    func eventCommitted(_ outcome: IngestOutcome) async {
        let fallback = String(outcome.deviceID.prefix(8))
        let name = (try? store.device(id: outcome.deviceID)?.name) ?? fallback
        await notifications.handleCommittedEvent(outcome, deviceName: name)
        await model?.refreshGaps()
        await diagnostics.record(
            .debug,
            category: "ingest",
            message: "\(String(outcome.deviceID.prefix(12))) \(outcome.generation) seq \(outcome.sequence) \(outcome.kind.rawValue), replayed \(outcome.replayed)"
        )
    }

    func backlogCompleted(_ summary: BacklogSummary) async {
        await notifications.postBacklogSummary(summary)
        await diagnostics.record(
            .info,
            category: "backlog",
            message: "\(String(summary.deviceID.prefix(12))) committed \(summary.notificationCount) notifications and \(summary.otpCount) codes"
        )
    }

    func notificationRemoved(deviceID: String, key: String) async {
        notifications.removeDelivered(deviceID: deviceID, key: key)
    }
}
