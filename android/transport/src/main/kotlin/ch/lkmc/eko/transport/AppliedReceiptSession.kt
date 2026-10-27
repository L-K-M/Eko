package ch.lkmc.eko.transport

import android.content.Context
import android.net.Network
import android.util.Base64
import ch.lkmc.eko.core.Frame
import ch.lkmc.eko.core.FrameCodec
import ch.lkmc.eko.core.JSON_FRAME_TYPE
import ch.lkmc.eko.pairing.AndroidIdentity
import ch.lkmc.eko.pairing.AppliedUnpairReceipt
import ch.lkmc.eko.pairing.IdentityStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

internal class AppliedReceiptSession(context: Context) {
    private val identityStore = IdentityStore.get(context.applicationContext)

    suspend fun run(receipt: AppliedUnpairReceipt, network: Network) {
        val identity = AndroidIdentity.getOrCreate(identityStore)
        val epoch = identityStore.nextConnectionEpoch()
        val pin = Base64.decode(receipt.certificateDerBase64, Base64.NO_WRAP)
        val connection = withContext(Dispatchers.IO) {
            TlsConnector(identity).connectPinned(network, receipt.endpoint, pin)
        }
        connection.socket.use { socket ->
            socket.soTimeout = 10_000
            withContext(Dispatchers.IO) {
                FrameCodec.write(
                    socket.outputStream,
                    Frame(JSON_FRAME_TYPE, WireJson.helloUnpair(identity, epoch, receipt.unpairId).toString().encodeToByteArray()),
                )
                FrameCodec.write(
                    socket.outputStream,
                    Frame(
                        JSON_FRAME_TYPE,
                        buildJsonObject {
                            put("type", "unpair_ack")
                            put("unpair_id", receipt.unpairId)
                            put("initiator_id", receipt.initiatorId)
                            put("peer_id", receipt.peerId)
                            put("status", "already_applied")
                        }.toString().encodeToByteArray(),
                    ),
                )
            }
        }
    }
}
