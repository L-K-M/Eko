package dev.eko.transport

import android.content.Context
import android.net.Network
import android.util.Base64
import dev.eko.core.Frame
import dev.eko.core.FrameCodec
import dev.eko.core.JSON_FRAME_TYPE
import dev.eko.core.ProtocolException
import dev.eko.pairing.AndroidIdentity
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.PairingCoordinator
import dev.eko.pairing.RevokedPeerTombstone
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal sealed interface TombstoneInbound {
    data class Acknowledged(val status: String) : TombstoneInbound
    data class CrossedUnpair(val unpairId: String, val initiatorId: String, val peerId: String) : TombstoneInbound
    data class Diagnostic(val code: String) : TombstoneInbound
}

internal fun parseTombstoneInbound(
    message: JsonObject,
    tombstone: RevokedPeerTombstone,
    localDeviceId: String,
): TombstoneInbound = when (message.strictString("type")) {
    "unpair_ack" -> {
        if (message.strictString("unpair_id") != tombstone.unpairId ||
            message.strictString("initiator_id") != localDeviceId ||
            message.strictString("peer_id") != tombstone.deviceId
        ) throw ProtocolException("Unpair acknowledgement does not match the pending tombstone request")
        val status = message.strictString("status")
        if (status != "applied" && status != "already_applied") {
            throw ProtocolException("Unpair acknowledgement carries an unknown status")
        }
        TombstoneInbound.Acknowledged(status)
    }
    "unpair" -> {
        val unpairId = message.strictString("unpair_id").requireUuidV4("unpair_id")
        val initiatorId = message.strictString("initiator_id")
        val peerId = message.strictString("peer_id")
        if (initiatorId != tombstone.deviceId || peerId != localDeviceId ||
            message.strictString("reason") !in setOf("user_request", "identity_replaced")
        ) throw ProtocolException("Crossed unpair identities do not match the authenticated connection")
        TombstoneInbound.CrossedUnpair(unpairId, initiatorId, peerId)
    }
    "error" -> {
        val code = message.strictString("code")
        if (message.strictBoolean("fatal")) throw ProtocolException("Tombstoned peer closed the exchange: $code")
        TombstoneInbound.Diagnostic(code)
    }
    else -> throw ProtocolException("Tombstoned peer sent data outside the restricted unpair exchange")
}

internal class TombstoneSession(context: Context) {
    private val appContext = context.applicationContext
    private val identityStore = IdentityStore.get(appContext)

    suspend fun run(tombstone: RevokedPeerTombstone, network: Network) {
        val identity = AndroidIdentity.getOrCreate(identityStore)
        val epoch = identityStore.nextConnectionEpoch()
        val pin = Base64.decode(tombstone.certificateDerBase64, Base64.NO_WRAP)
        val connection = withContext(Dispatchers.IO) {
            TlsConnector(identity).connectPinned(network, tombstone.endpoint, pin)
        }
        connection.socket.use { socket ->
            socket.soTimeout = TIMEOUT_MS
            withContext(Dispatchers.IO) {
                FrameCodec.write(
                    socket.outputStream,
                    Frame(JSON_FRAME_TYPE, WireJson.helloUnpair(identity, epoch, tombstone.unpairId).toString().encodeToByteArray()),
                )
                FrameCodec.write(
                    socket.outputStream,
                    Frame(
                        JSON_FRAME_TYPE,
                        buildJsonObject {
                            put("type", "unpair")
                            put("unpair_id", tombstone.unpairId)
                            put("initiator_id", identity.deviceId)
                            put("peer_id", tombstone.deviceId)
                            put("reason", "user_request")
                        }.toString().encodeToByteArray(),
                    ),
                )
                var acknowledged = false
                while (!acknowledged) {
                    val response = FrameCodec.readJson(socket.inputStream)
                    when (val inbound = parseTombstoneInbound(response, tombstone, identity.deviceId)) {
                        is TombstoneInbound.Acknowledged -> acknowledged = true
                        is TombstoneInbound.CrossedUnpair -> {
                            val alreadyApplied = identityStore.read().appliedUnpairReceipts
                                .any { it.unpairId == inbound.unpairId }
                            PairingCoordinator(appContext).applyRemoteUnpair(
                                tombstone.deviceId,
                                inbound.unpairId,
                                inbound.initiatorId,
                                inbound.peerId,
                            )
                            FrameCodec.write(
                                socket.outputStream,
                                Frame(
                                    JSON_FRAME_TYPE,
                                    WireJson.unpairAck(
                                        inbound.unpairId,
                                        inbound.initiatorId,
                                        identity.deviceId,
                                        if (alreadyApplied) "already_applied" else "applied",
                                    ).toString().encodeToByteArray(),
                                ),
                            )
                        }
                        is TombstoneInbound.Diagnostic ->
                            TransportRuntime.log("Restricted unpair diagnostic for ${tombstone.deviceId}: ${inbound.code}")
                    }
                }
            }
        }
        identityStore.clearTombstone(tombstone.deviceId)
    }

    private companion object {
        const val TIMEOUT_MS = 10_000
    }
}
