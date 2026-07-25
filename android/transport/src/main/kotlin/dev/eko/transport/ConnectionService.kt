package dev.eko.transport

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import dev.eko.core.FullJitterBackoff
import dev.eko.outbox.CursorAheadOfHighWaterException
import dev.eko.outbox.EventStoreResetter
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.MacDiscovery
import dev.eko.pairing.PeerEndpoint
import dev.eko.pairing.RevokedPeerTombstone
import java.util.concurrent.ConcurrentHashMap
import kotlin.coroutines.coroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.mapNotNull
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class ConnectionService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val peerJobs = ConcurrentHashMap<String, Job>()
    private val tombstoneJobs = ConcurrentHashMap<String, Job>()
    private val receiptJobs = ConcurrentHashMap<String, Job>()
    private val resetInProgress = MutableStateFlow(false)
    private lateinit var identityStore: IdentityStore
    private lateinit var networkMonitor: EligibleNetworkMonitor

    override fun onCreate() {
        super.onCreate()
        identityStore = IdentityStore.get(this)
        networkMonitor = EligibleNetworkMonitor(this)
        createNotificationChannel()
        showForeground(buildNotification(TransportRuntime.state.value))
        TransportRuntime.running(true)
        scope.launch {
            identityStore.state.collect(::reconcileJobs)
        }
        scope.launch {
            TransportRuntime.state.collect { showForeground(buildNotification(it)) }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int = START_STICKY

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        peerJobs.values.forEach(Job::cancel)
        tombstoneJobs.values.forEach(Job::cancel)
        receiptJobs.values.forEach(Job::cancel)
        networkMonitor.close()
        scope.cancel()
        TransportRuntime.running(false)
        super.onDestroy()
    }

    private fun reconcileJobs(state: dev.eko.pairing.IdentityState) {
        val plan = planPeerJobs(state, peerJobs.keys.toSet(), resetInProgress.value)
        plan.stopPeerIds.forEach { id ->
            peerJobs.remove(id)?.cancel()
            TransportRuntime.removePeer(id)
        }
        plan.markPausedIds.forEach { id -> TransportRuntime.peer(id, PeerTransportState.Paused) }
        plan.startPeers.forEach { peer ->
            peerJobs.computeIfAbsent(peer.deviceId) { id ->
                scope.launch { runPeer(id) }.also { job ->
                    job.invokeOnCompletion {
                        peerJobs.remove(id, job)
                        TransportRuntime.removePeer(id)
                        scope.launch { reconcileJobs(identityStore.read()) }
                    }
                }
            }
        }

        val tombstoneIds = state.tombstones.map(RevokedPeerTombstone::deviceId).toSet()
        tombstoneJobs.keys.filterNot(tombstoneIds::contains).forEach { id -> tombstoneJobs.remove(id)?.cancel() }
        state.tombstones.forEach { tombstone ->
            tombstoneJobs.computeIfAbsent(tombstone.deviceId) { id -> scope.launch { runTombstone(id) } }
        }

        val receiptIds = state.appliedUnpairReceipts.map { it.unpairId }.toSet()
        receiptJobs.keys.filterNot(receiptIds::contains).forEach { id -> receiptJobs.remove(id)?.cancel() }
        state.appliedUnpairReceipts.forEach { receipt ->
            if (peerJobs.containsKey(receipt.deviceId)) return@forEach
            receiptJobs.computeIfAbsent(receipt.unpairId) {
                scope.launch {
                    val network = networkMonitor.awaitNetwork()
                    runCatching { AppliedReceiptSession(this@ConnectionService).run(receipt, network) }
                        .onFailure { error -> TransportRuntime.log("Applied unpair receipt delivery failed: ${error.message}") }
                }
            }
        }
    }

    private suspend fun runPeer(deviceId: String) {
        val backoff = FullJitterBackoff()
        while (true) {
            val state = identityStore.read()
            val peer = state.confirmedPeers.firstOrNull { it.deviceId == deviceId } ?: return
            if (state.forwardingPaused) {
                TransportRuntime.peer(deviceId, PeerTransportState.Paused)
                identityStore.state.map { it.forwardingPaused }.distinctUntilChanged().filter { !it }.first()
                continue
            }
            TransportRuntime.peer(deviceId, PeerTransportState.WaitingForNetwork)
            val network = networkMonitor.awaitNetwork()
            val started = SystemClock.elapsedRealtime()
            try {
                NormalPeerSession(this).run(peer, network)
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (rollback: CursorAheadOfHighWaterException) {
                TransportRuntime.log("$deviceId requested cursor ${rollback.cursor} above ${rollback.highWater}; resetting generation")
                coordinateGenerationReset()
                backoff.reset()
                continue
            } catch (error: Throwable) {
                TransportRuntime.log("$deviceId disconnected: ${error.message ?: error.javaClass.simpleName}")
                TransportRuntime.peer(deviceId, PeerTransportState.Failed(error.message ?: error.javaClass.simpleName))
            }
            backoff.recordStableConnection(SystemClock.elapsedRealtime() - started)
            if (refreshEndpointFromDiscovery(deviceId)) {
                backoff.reset()
                continue
            }
            val wait = backoff.nextDelayMillis()
            TransportRuntime.peer(deviceId, PeerTransportState.Reconnecting(backoff.attempt, wait))
            withTimeoutOrNull(wait) { networkMonitor.changes.first() }
        }
    }

    private suspend fun coordinateGenerationReset() {
        resetInProgress.value = true
        try {
            val self = coroutineContext[Job]
            val others = peerJobs.filterValues { it != self }
            others.keys.forEach { peerJobs.remove(it, others.getValue(it)) }
            others.values.forEach { it.cancel() }
            others.values.forEach { it.join() }
            EventStoreResetter.reset(this, identityStore)
        } finally {
            resetInProgress.value = false
        }
        reconcileJobs(identityStore.read())
    }

    private suspend fun refreshEndpointFromDiscovery(deviceId: String): Boolean {
        val discovery = MacDiscovery(this)
        return try {
            discovery.start()
            val match = withTimeoutOrNull(5_000) {
                discovery.devices.mapNotNull { devices ->
                    devices.firstOrNull { it.fingerprint?.lowercase() == deviceId }
                }.first()
            } ?: return false
            identityStore.updateEndpoint(deviceId, PeerEndpoint(match.host, match.port))
            TransportRuntime.log("$deviceId endpoint refreshed from a matching-fingerprint mDNS hint; TLS still decides trust")
            true
        } finally {
            discovery.close()
        }
    }

    private suspend fun runTombstone(deviceId: String) {
        val backoff = FullJitterBackoff()
        repeat(MAX_TOMBSTONE_DIALS_PER_PROCESS) {
            val tombstone = identityStore.read().tombstones.firstOrNull { it.deviceId == deviceId } ?: return
            val network = networkMonitor.awaitNetwork()
            try {
                TombstoneSession(this).run(tombstone, network)
                return
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Throwable) {
                TransportRuntime.log("Restricted unpair for $deviceId failed: ${error.message ?: error.javaClass.simpleName}")
            }
            val wait = backoff.nextDelayMillis()
            withTimeoutOrNull(wait) { networkMonitor.changes.first() }
        }
        TransportRuntime.log("Restricted unpair for $deviceId reached its bounded retry limit")
    }

    private fun buildNotification(snapshot: TransportSnapshot): Notification {
        val paused = snapshot.peers.values.any { it is PeerTransportState.Paused }
        val connected = snapshot.peers.values.count { it is PeerTransportState.Connected }
        val text = when {
            paused -> getString(R.string.eko_connection_paused)
            connected > 0 -> getString(R.string.eko_connection_connected, connected)
            else -> getString(R.string.eko_connection_reconnecting)
        }
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(this, 0, it, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        }
        val action = if (paused) ACTION_RESUME else ACTION_PAUSE
        val actionLabel = if (paused) R.string.eko_resume else R.string.eko_pause
        val actionIntent = PendingIntent.getBroadcast(
            this,
            action.hashCode(),
            Intent(this, TransportActionReceiver::class.java).setAction(action),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_eko_status)
            .setContentTitle(getString(R.string.eko_connection_title))
            .setContentText(text)
            .setContentIntent(contentIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .addAction(0, getString(actionLabel), actionIntent)
            .build()
    }

    private fun showForeground(notification: Notification) {
        val type = if (Build.VERSION.SDK_INT >= 29) ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE else 0
        ServiceCompat.startForeground(this, NOTIFICATION_ID, notification, type)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < 26) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            getString(R.string.eko_connection_channel_name),
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = getString(R.string.eko_connection_channel_description)
            setShowBadge(false)
        }
        getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    companion object {
        const val ACTION_PAUSE = "dev.eko.transport.action.PAUSE"
        const val ACTION_RESUME = "dev.eko.transport.action.RESUME"
        private const val CHANNEL_ID = "eko_connection"
        private const val NOTIFICATION_ID = 1_700
        private const val MAX_TOMBSTONE_DIALS_PER_PROCESS = 8

        fun requestStart(context: Context): Boolean {
            if (IdentityStore.isStartBlocked(context)) return false
            if (!IdentityStore.hasKnownPeer(context)) return false
            return try {
                ContextCompat.startForegroundService(context, Intent(context, ConnectionService::class.java))
                true
            } catch (error: RuntimeException) {
                TransportRuntime.log("Foreground service start denied: ${error.message ?: error.javaClass.simpleName}")
                false
            }
        }
    }
}
