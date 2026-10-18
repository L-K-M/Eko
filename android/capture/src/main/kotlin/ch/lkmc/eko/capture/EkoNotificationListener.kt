package dev.eko.capture

import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import dev.eko.core.NotificationSanitizer
import dev.eko.outbox.NotificationSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeoutOrNull

internal fun collectReconciliationSnapshots(
    activeNotifications: () -> Array<StatusBarNotification>,
    extract: (StatusBarNotification) -> ExtractedNotification?,
    onWriterOverflow: () -> Unit,
): List<NotificationSnapshot>? {
    val active = try {
        activeNotifications()
    } catch (error: RuntimeException) {
        return null
    }
    return active.mapNotNull { sbn ->
        val extracted = extract(sbn)
        if (extracted?.writerOverflow == true) onWriterOverflow()
        extracted?.snapshot
    }
}

class EkoNotificationListener : NotificationListenerService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var writer: SerializedNotificationWriter
    private lateinit var extractor: NotificationExtractor
    private lateinit var diagnostics: CaptureDiagnostics
    private val mainHandler = Handler(Looper.getMainLooper())
    private var reconciliationRetries = 0

    // One instance, held for the process. `mainHandler.post(::enqueueReconciliation)`
    // SAM-converts to a fresh Runnable on every evaluation, and removeCallbacks matches
    // by reference identity — so posting and removing via `::enqueueReconciliation`
    // removed nothing, and retries kept firing against a destroyed service. Android Lint
    // flags exactly this as ImplicitSamInstance.
    private val reconcileRunnable = Runnable { enqueueReconciliation() }

    override fun onCreate() {
        super.onCreate()
        diagnostics = CaptureDiagnostics.get(this)
        extractor = NotificationExtractor(this)
        writer = SerializedNotificationWriter.create(this, scope)
    }

    override fun onListenerConnected() {
        super.onListenerConnected()
        diagnostics.connected(true)
        NotificationListenerController.onConnected(this)
        reconciliationRetries = 0
        val now = System.currentTimeMillis()
        diagnostics.disconnectedAt().takeIf { it > 0 }?.let { start ->
            if (writer.gap("listener_disconnected", start, now)) diagnostics.clearDisconnectedAt()
        }
        enqueueReconciliation()
    }

    override fun onListenerDisconnected() {
        diagnostics.connected(false)
        diagnostics.markDisconnectedAt(System.currentTimeMillis())
        NotificationListenerController.onDisconnected(this)
        super.onListenerDisconnected()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification, rankingMap: RankingMap) {
        diagnostics.callback()
        extractor.extract(sbn, rankingMap, currentInterruptionFilter)?.also(::recordRedaction)?.let { extracted ->
            if (extracted.writerOverflow) {
                val now = System.currentTimeMillis()
                writer.gap("writer_overflow", now, now)
            } else {
                extracted.snapshot?.let { writer.post(it) }
            }
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification, rankingMap: RankingMap, reason: Int) {
        diagnostics.callback()
        if (!NotificationSanitizer.isValidOpaqueIdentifier(sbn.key, NotificationSanitizer.KEY_BYTES) ||
            !NotificationSanitizer.isValidOpaqueIdentifier(sbn.packageName, NotificationSanitizer.PACKAGE_BYTES)
        ) {
            val now = System.currentTimeMillis()
            writer.gap("writer_overflow", now, now)
        } else {
            writer.remove(sbn.key, reason)
        }
    }

    override fun onInterruptionFilterChanged(interruptionFilter: Int) {
        diagnostics.interruptionFilter(interruptionFilter)
    }

    private companion object {
        const val MAX_RECONCILIATION_RETRIES = 3
        const val RECONCILIATION_RETRY_MS = 5_000L

        // onDestroy runs on the main thread, so this is a hard ceiling on how long a
        // rebind can block: long enough for a handful of synchronous=FULL commits,
        // far short of the service ANR budget.
        const val DRAIN_TIMEOUT_MS = 1_500L
    }

    internal fun cancelFromPeer(key: String) {
        mainHandler.post { cancelNotification(key) }
    }

    internal fun reconcileFromApp() {
        mainHandler.post(reconcileRunnable)
    }

    override fun onDestroy() {
        NotificationListenerController.onDisconnected(this)
        mainHandler.removeCallbacks(reconcileRunnable)
        drainWriter()
        scope.cancel()
        super.onDestroy()
    }

    /**
     * Let the writer finish what it already accepted before the scope that owns its
     * consumer is cancelled.
     *
     * `writer.close()` is a graceful close whose contract is that the consumer keeps
     * draining; `scope.cancel()` on the next line broke that contract, discarding every
     * buffered [CaptureCommand] and rolling back the one mid-transaction. Those
     * notifications had already been accepted from the system, so the loss violated
     * "persist durably at post time, before any send attempt" — and it was invisible,
     * because `onListenerDisconnected` records a gap covering the disconnect interval
     * while the dropped commands were posted *before* it.
     *
     * Teardown is common: `supportedRebind()` (the repair flow, HealthWorker, unpair),
     * MY_PACKAGE_REPLACED on app update, the user toggling notification access.
     *
     * Bounded, because onDestroy runs on the main thread and a wedged database must not
     * turn a rebind into an ANR. A drain that does not finish in time is itself capture
     * evidence, so it is recorded as one — the disconnect marker makes the next
     * onListenerConnected commit a suspected gap, which is the machinery that already
     * exists for "the listener was not capturing during this window".
     */
    private fun drainWriter() {
        val startedWall = System.currentTimeMillis()
        val drained = runBlocking(NonCancellable) {
            withTimeoutOrNull(DRAIN_TIMEOUT_MS) { writer.closeAndDrain() } != null
        }
        if (drained && writer.pending == 0) return
        diagnostics.overflow()
        // Do not overwrite an earlier mark: onListenerDisconnected usually ran first,
        // and its timestamp bounds a strictly larger, more honest window.
        if (diagnostics.disconnectedAt() <= 0) diagnostics.markDisconnectedAt(startedWall)
    }

    private fun recordRedaction(extracted: ExtractedNotification) {
        if (extracted.redacted) diagnostics.redactionDetected()
    }

    private fun enqueueReconciliation() {
        val snapshots = collectReconciliationSnapshots(
            activeNotifications = { activeNotifications },
            extract = { sbn ->
                extractor.extract(sbn, currentRanking, currentInterruptionFilter)?.also(::recordRedaction)
            },
            onWriterOverflow = {
                val now = System.currentTimeMillis()
                writer.gap("writer_overflow", now, now)
            },
        )
        if (snapshots == null) {
            diagnostics.reconciliationFailed()
            if (reconciliationRetries < MAX_RECONCILIATION_RETRIES) {
                reconciliationRetries += 1
                mainHandler.postDelayed(reconcileRunnable, RECONCILIATION_RETRY_MS)
            }
            return
        }
        writer.reconcile(snapshots) { NotificationListenerController.onReconciled(this) }
    }
}
