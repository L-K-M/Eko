import EkoCore
import Foundation

final class AppSessionSink: SessionEventSink, @unchecked Sendable {
    private weak var model: AppModel?
    private let store: EkoStore
    private let notifications: NotificationCoordinator
    private let diagnostics: DiagnosticsRecorder

    // Guards the two caches below. The sink is called from the session actor, so this is
    // uncontended in practice; the lock is here because nothing structurally guarantees
    // a single caller.
    private let lock = NSLock()
    private var deviceNames: [String: String] = [:]
    private var replayedSinceBacklog: [String: Int] = [:]

    init(model: AppModel, store: EkoStore, notifications: NotificationCoordinator, diagnostics: DiagnosticsRecorder) {
        self.model = model
        self.store = store
        self.notifications = notifications
        self.diagnostics = diagnostics
    }

    func connectionStateChanged(deviceID: String, state: DeviceConnectionState) async {
        // A session transition is the right moment to (re)read the name: it is the only
        // point at which it can have changed, and it takes the per-event lookup below
        // off the ingest path entirely.
        refreshCachedName(deviceID: deviceID)
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

    /// Called for every non-duplicate ingested event, including every replayed backlog
    /// event — up to the design's 2'000-per-Mac stress case.
    ///
    /// It used to do three expensive things per event: a `pool.read` for a device name
    /// that is constant for the whole session; a `refreshGaps()` hop onto the MainActor,
    /// where it ran a *synchronous* GRDB read and then assigned to a `@Published`
    /// property, invalidating the entire SwiftUI tree and the status item; and an
    /// eagerly-interpolated debug record, one actor hop each. A 2'000-event replay was
    /// 2'000 background reads, 2'000 blocking main-thread reads and 2'000 full UI
    /// invalidations, all of which the session awaited before ACKing.
    ///
    /// Note the coordinator below already early-outs on
    /// `guard !outcome.duplicate, !outcome.replayed` — this sink was doing its work
    /// *before* that guard applied.
    func eventCommitted(_ outcome: IngestOutcome) async {
        let name = cachedName(deviceID: outcome.deviceID)
        await notifications.handleCommittedEvent(outcome, deviceName: name)

        // Gaps only change when a gap is committed. Refreshing on every posted/updated/
        // removed event was pure churn: the gap set is unchanged for the overwhelming
        // majority of a replay.
        if outcome.kind == .captureGap {
            await model?.refreshGaps()
        }

        if outcome.replayed {
            // One aggregate line at backlogCompleted instead of one per replayed event.
            lock.lock()
            replayedSinceBacklog[outcome.deviceID, default: 0] += 1
            lock.unlock()
            return
        }

        await diagnostics.record(
            .debug,
            category: "ingest",
            message: "\(String(outcome.deviceID.prefix(12))) \(outcome.generation) seq \(outcome.sequence) \(outcome.kind.rawValue)"
        )
    }

    func backlogCompleted(_ summary: BacklogSummary) async {
        await notifications.postBacklogSummary(summary)

        lock.lock()
        let replayed = replayedSinceBacklog.removeValue(forKey: summary.deviceID) ?? 0
        lock.unlock()

        // The backlog is the one point at which a retention or capture gap can have been
        // committed without a per-event refresh having noticed a late-arriving one.
        await model?.refreshGaps()
        await diagnostics.record(
            .info,
            category: "backlog",
            message: "\(String(summary.deviceID.prefix(12))) committed \(summary.notificationCount) notifications and \(summary.otpCount) codes, \(replayed) replayed events"
        )
    }

    func notificationRemoved(deviceID: String, key: String) async {
        notifications.removeDelivered(deviceID: deviceID, key: key)
    }

    private func cachedName(deviceID: String) -> String {
        lock.lock()
        let cached = deviceNames[deviceID]
        lock.unlock()
        if let cached { return cached }
        return refreshCachedName(deviceID: deviceID)
    }

    @discardableResult
    private func refreshCachedName(deviceID: String) -> String {
        let name = (try? store.device(id: deviceID)?.name) ?? String(deviceID.prefix(8))
        lock.lock()
        deviceNames[deviceID] = name
        lock.unlock()
        return name
    }
}
