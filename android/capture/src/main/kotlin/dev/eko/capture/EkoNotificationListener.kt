package dev.eko.capture

import android.os.Handler
import android.os.Looper
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import dev.eko.core.NotificationSanitizer
import dev.eko.outbox.NotificationSnapshot
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel

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
    }

    internal fun cancelFromPeer(key: String) {
        mainHandler.post { cancelNotification(key) }
    }

    internal fun reconcileFromApp() {
        mainHandler.post(::enqueueReconciliation)
    }

    override fun onDestroy() {
        NotificationListenerController.onDisconnected(this)
        mainHandler.removeCallbacks(::enqueueReconciliation)
        writer.close()
        scope.cancel()
        super.onDestroy()
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
                mainHandler.postDelayed(::enqueueReconciliation, RECONCILIATION_RETRY_MS)
            }
            return
        }
        writer.reconcile(snapshots) { NotificationListenerController.onReconciled(this) }
    }
}
