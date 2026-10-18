package dev.eko.transport

import android.content.Context
import android.net.Network
import android.os.SystemClock
import android.util.Base64
import dev.eko.capture.NotificationListenerController
import dev.eko.core.FrameCodec
import dev.eko.core.ProtocolException
import dev.eko.outbox.CursorAheadOfHighWaterException
import dev.eko.outbox.EventStoreProvider
import dev.eko.pairing.AndroidIdentity
import dev.eko.pairing.ConfirmedPeer
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.CdmAssociationController
import dev.eko.pairing.PairingCoordinator
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference
import kotlin.coroutines.coroutineContext
import kotlin.random.Random
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject

internal class NormalPeerSession(context: Context) {
    private val appContext = context.applicationContext
    private val identityStore = IdentityStore.get(appContext)

    suspend fun run(peer: ConfirmedPeer, network: Network) {
        val repository = EventStoreProvider.repository(appContext)
        val metadata = repository.initialize()
        val identity = AndroidIdentity.getOrCreate(identityStore)
        val epoch = identityStore.nextConnectionEpoch()
        val peerCertificate = Base64.decode(peer.certificateDerBase64, Base64.NO_WRAP)
        val connection = withContext(Dispatchers.IO) {
            TlsConnector(identity).connectPinned(network, peer.endpoint, peerCertificate)
        }
        val socket = connection.socket
        val completionHandle = coroutineContext.job.invokeOnCompletion { runCatching { socket.close() } }
        try {
            socket.soTimeout = HELLO_TIMEOUT_MS
            withContext(Dispatchers.IO) {
                dev.eko.core.FrameCodec.write(
                    socket.outputStream,
                    dev.eko.core.Frame(
                        dev.eko.core.JSON_FRAME_TYPE,
                        WireJson.helloNormal(identity, metadata.outboxGeneration, epoch).toString().encodeToByteArray(),
                    ),
                )
            }
            val welcome = withContext(Dispatchers.IO) { FrameCodec.readJson(socket.inputStream) }
            if (welcome.strictString("type") == "unpair") {
                handleUnpairBeforeWelcome(welcome, peer, identity.deviceId, socket.outputStream)
                return
            }
            val accepted = validateWelcome(welcome, metadata.outboxGeneration, peer)
            identityStore.updateHighestProtocol(peer.deviceId, accepted.protocol)
            socket.soTimeout = 0

            if (NotificationListenerController.hasAccess(appContext)) {
                // Not withTimeout: TimeoutCancellationException IS-A
                // CancellationException, so runPeer's rethrow-cancellation
                // catch treated the expiry as job cancellation — the peer job
                // died and restarted with a fresh backoff, hammering the Mac
                // with a full TLS handshake every ~15 s and never showing a
                // Failed state. A plain exception takes the normal failure
                // branch: Failed status plus growing backoff.
                withTimeoutOrNull(RECONCILIATION_TIMEOUT_MS) {
                    NotificationListenerController.reconciled.filter { it }.first()
                } ?: throw ProtocolException("Listener reconciliation timed out")
            }
            val snapshot = try {
                repository.backlog(peer.deviceId, accepted.cursor)
            } catch (rollback: CursorAheadOfHighWaterException) {
                withContext(NonCancellable + Dispatchers.IO) {
                    runCatching {
                        FrameCodec.write(
                            socket.outputStream,
                            dev.eko.core.Frame(
                                dev.eko.core.JSON_FRAME_TYPE,
                                WireJson.error("store_reset").toString().encodeToByteArray(),
                            ),
                        )
                    }
                }
                throw rollback
            }
            TransportRuntime.peer(peer.deviceId, PeerTransportState.Syncing(snapshot.eventSeqs.size))
            val inbound = SessionInboundValidator(accepted.capabilities.toSet(), peer.deviceId, identity.deviceId)
            coroutineScope {
                val outbound = OutboundActor(this, socket.outputStream, accepted.cursor)
                try {
                    val syncId = UUID.randomUUID().toString()
                    outbound.sendFrames(WireJson.backlogStart(snapshot, syncId))
                    // Replay page-by-page: the snapshot pins positions, payloads are
                    // loaded only when sent, so a full retention window of large
                    // events cannot exhaust the heap mid-sync.
                    snapshot.eventSeqs.chunked(BACKLOG_PAGE_SIZE).forEach { pageSeqs ->
                        val page = repository.replayPage(pageSeqs)
                        outbound.sendFrames(page.map { WireJson.backlogEvent(it, syncId) })
                    }
                    outbound.sendFrames(WireJson.backlogEnd(snapshot, syncId))
                    if (snapshot.eventSeqs.isNotEmpty()) TransportRuntime.forwarded(peer.deviceId)
                    val connectedAtWall = System.currentTimeMillis()
                    TransportRuntime.peer(peer.deviceId, PeerTransportState.Connected(connectedAtWall, accepted.cursor))
                    val lastPong = AtomicLong(SystemClock.elapsedRealtime())
                    val pendingPing = AtomicReference<PendingPing?>(null)
                    val reader = launch(Dispatchers.IO) {
                        readInbound(peer, identity.deviceId, inbound, outbound, lastPong, pendingPing, connectedAtWall, socket.inputStream)
                    }
                    val heartbeat = launch {
                        delay(Random.nextLong(15_000, 35_001))
                        while (true) {
                            val sentAt = SystemClock.elapsedRealtime()
                            val ping = PendingPing(UUID.randomUUID().toString(), System.currentTimeMillis())
                            pendingPing.set(ping)
                            outbound.send(WireJson.ping(ping.id, ping.phoneTime))
                            delay(PONG_DEADLINE_MS)
                            if (pendingPing.get() == ping || lastPong.get() < sentAt) {
                                socket.close()
                                throw ProtocolException("Heartbeat pong deadline expired")
                            }
                            delay((PING_INTERVAL_MS - PONG_DEADLINE_MS).coerceAtLeast(0))
                        }
                    }

                    var sentThrough = snapshot.highWater
                    repository.observeMetadata().collect { current ->
                        while (sentThrough < current.lastAssignedSeq) {
                            val events = repository.eventsAfter(sentThrough)
                            if (events.isEmpty() || events.first().seq != sentThrough + 1) {
                                throw ProtocolException("Retention advanced during a live stream; resync required")
                            }
                            for (event in events) {
                                if (event.seq > current.lastAssignedSeq) break
                                outbound.send(WireJson.event(event, replayed = false), sequence = event.seq)
                                TransportRuntime.forwarded(peer.deviceId)
                                sentThrough = event.seq
                            }
                        }
                    }
                    reader.join()
                    heartbeat.cancel()
                } finally {
                    outbound.close()
                }
            }
        } finally {
            completionHandle.dispose()
            runCatching { socket.close() }
        }
    }

    private suspend fun readInbound(
        peer: ConfirmedPeer,
        localDeviceId: String,
        inbound: SessionInboundValidator,
        outbound: OutboundActor,
        lastPong: AtomicLong,
        pendingPing: AtomicReference<PendingPing?>,
        connectedAtWall: Long,
        input: java.io.InputStream,
    ) {
        val repository = EventStoreProvider.repository(appContext)
        while (true) {
            val message = FrameCodec.readJson(input)
            when (val control = inbound.validate(message)) {
                is InboundControl.Ack -> {
                    try {
                        repository.acknowledge(peer.deviceId, control.seq, outbound.authorizedThrough())
                    } catch (invalid: dev.eko.outbox.InvalidAcknowledgementException) {
                        outbound.send(WireJson.error("invalid_ack"))
                        throw invalid
                    }
                    TransportRuntime.peer(peer.deviceId, PeerTransportState.Connected(connectedAtWall, control.seq))
                }
                is InboundControl.Pong -> {
                    val pending = pendingPing.get() ?: throw ProtocolException("Unsolicited pong")
                    if (control.pingId != pending.id || control.phoneTime != pending.phoneTime) {
                        throw ProtocolException("Pong does not exactly echo the pending ping")
                    }
                    if (!pendingPing.compareAndSet(pending, null)) throw ProtocolException("Duplicate pong")
                    lastPong.set(SystemClock.elapsedRealtime())
                }
                is InboundControl.Dismiss -> NotificationListenerController.dismiss(control.key)
                is InboundControl.Fetch -> {
                    val results = repository.fetch(control.keys)
                    outbound.sendBatch(results.map { WireJson.fetch(it, control.requestId) })
                }
                is InboundControl.Unpair -> {
                    val alreadyApplied = identityStore.read().appliedUnpairReceipts.any { it.unpairId == control.unpairId }
                    withContext(NonCancellable) {
                        PairingCoordinator(appContext).applyRemoteUnpair(
                            peer.deviceId,
                            control.unpairId,
                            control.initiatorId,
                            control.peerId,
                        )
                        val cdm = CdmAssociationController(appContext, identityStore) {
                            NotificationListenerController.supportedRebind(appContext)
                        }
                        cdm.inventory().forEach { cdm.removeIfUnused(it.id) }
                        outbound.send(
                            WireJson.unpairAck(
                                control.unpairId,
                                control.initiatorId,
                                localDeviceId,
                                if (alreadyApplied) "already_applied" else "applied",
                            ),
                        )
                    }
                    throw ProtocolException("Peer completed unpair")
                }
                is InboundControl.ErrorFrame -> {
                    if (control.fatal) throw ProtocolException("Peer closed session: ${control.code}")
                    TransportRuntime.log("Non-fatal peer diagnostic for ${peer.deviceId}: ${control.code}")
                }
                InboundControl.Ignored -> Unit
            }
        }
    }

    private fun validateWelcome(message: JsonObject, generation: String, peer: ConfirmedPeer): Welcome {
        if (message.strictString("type") != "welcome") throw ProtocolException("First peer frame must be welcome")
        val protocol = message.strictLong("proto")
        if (protocol != 1L || protocol < peer.highestProtocol) throw ProtocolException("Protocol downgrade or incompatibility")
        if (message.strictString("outbox_gen") != generation) throw ProtocolException("Welcome generation does not match hello")
        val macName = message.strictString("mac_name")
        if (macName.isEmpty() || macName.length > 256) throw ProtocolException("Welcome mac_name is outside the display-name limits")
        val cursor = message.strictLong("cursor")
        if (cursor < 0) throw ProtocolException("Negative cursor")
        val caps = message.stringList("caps")
        if ("notif" !in caps || caps.size > 64 || caps.distinct().size != caps.size ||
            caps.any { it !in WireJson.capabilities || !CAP_NAME.matches(it) }
        ) {
            throw ProtocolException("Peer returned an invalid capability intersection")
        }
        if (message.strictString("device_id") != peer.deviceId) {
            throw ProtocolException("Welcome identity does not match the pinned TLS peer")
        }
        return Welcome(protocol.toInt(), cursor, caps)
    }

    private suspend fun handleUnpairBeforeWelcome(
        message: JsonObject,
        peer: ConfirmedPeer,
        localDeviceId: String,
        output: java.io.OutputStream,
    ) = withContext(NonCancellable) {
        val unpairId = message.strictString("unpair_id").requireUuidV4("unpair_id")
        val initiatorId = message.strictString("initiator_id")
        val peerId = message.strictString("peer_id")
        if (initiatorId != peer.deviceId || peerId != localDeviceId ||
            message.strictString("reason") !in setOf("user_request", "identity_replaced")
        ) throw ProtocolException("Restricted unpair identities do not match TLS")
        PairingCoordinator(appContext).applyRemoteUnpair(peer.deviceId, unpairId, initiatorId, peerId)
        val cdm = CdmAssociationController(appContext, identityStore) {
            NotificationListenerController.supportedRebind(appContext)
        }
        cdm.inventory().forEach { cdm.removeIfUnused(it.id) }
        withContext(Dispatchers.IO) {
            val ack = WireJson.unpairAck(unpairId, initiatorId, localDeviceId, "applied")
            dev.eko.core.FrameCodec.write(
                output,
                dev.eko.core.Frame(dev.eko.core.JSON_FRAME_TYPE, ack.toString().encodeToByteArray()),
            )
        }
    }

    private data class Welcome(val protocol: Int, val cursor: Long, val capabilities: List<String>)
    private data class PendingPing(val id: String, val phoneTime: Long)

    private companion object {
        const val HELLO_TIMEOUT_MS = 10_000
        const val PING_INTERVAL_MS = 25_000L
        const val PONG_DEADLINE_MS = 10_000L
        const val RECONCILIATION_TIMEOUT_MS = 15_000L
        const val BACKLOG_PAGE_SIZE = 100
        val CAP_NAME = Regex("^[a-z][a-z0-9_]{0,63}$")
    }
}
