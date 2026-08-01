package dev.eko.pairing

import dev.eko.core.StrictJson
import java.io.Closeable
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetSocketAddress
import java.net.SocketTimeoutException
import java.util.LinkedHashMap
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

data class UdpMacHint(
    val host: String,
    val port: Int,
    val name: String,
    val fingerprint: String,
    val seenAtWall: Long,
)

class UdpHintListener : Closeable {
    private val mutable = MutableStateFlow<List<UdpMacHint>>(emptyList())
    val hints = mutable.asStateFlow()
    private val lastPacketByHost = LinkedHashMap<String, Long>()
    private var lastAcceptedPacketAt = 0L
    private var socket: DatagramSocket? = null
    private var job: Job? = null

    fun start(scope: CoroutineScope) {
        if (job != null) return
        val listener = runCatching {
            DatagramSocket(null).apply {
                reuseAddress = true
                soTimeout = 1_000
                bind(InetSocketAddress(PORT))
            }
        }.getOrNull() ?: return
        socket = listener
        job = scope.launch(Dispatchers.IO) {
            val buffer = ByteArray(MAX_PACKET_BYTES + 1)
            while (isActive) {
                val packet = DatagramPacket(buffer, buffer.size)
                try {
                    listener.receive(packet)
                    if (packet.length > MAX_PACKET_BYTES) continue
                    val source = packet.address.hostAddress ?: continue
                    val now = System.currentTimeMillis()
                    // The per-source throttle below is keyed on the UDP source
                    // address, which a LAN sender forges freely — so it cannot be
                    // the only budget. This global accepted-packet throttle is
                    // source-independent and bounds how fast the hints list (and
                    // the recomposition it drives) can churn under a flood.
                    if (now - lastAcceptedPacketAt < MIN_GLOBAL_PACKET_INTERVAL_MS) continue
                    val previous = synchronized(lastPacketByHost) { lastPacketByHost[source] ?: 0 }
                    if (now - previous < MIN_PACKET_INTERVAL_MS) continue
                    parse(packet.data.copyOfRange(packet.offset, packet.offset + packet.length), source, now)?.let { hint ->
                        lastAcceptedPacketAt = now
                        synchronized(lastPacketByHost) {
                            lastPacketByHost[source] = now
                            while (lastPacketByHost.size > MAX_PEERS) {
                                lastPacketByHost.remove(lastPacketByHost.keys.first())
                            }
                        }
                        // Drop hints that stopped announcing: entries were only
                        // ever replaced by fingerprint, so a Mac that changed
                        // address or left advertised a stale endpoint forever.
                        // Cap the tracked hints too: forged-source packets with
                        // fresh fingerprints must not grow this list without
                        // bound while the pairing screen is open.
                        mutable.value = (mutable.value.filterNot { it.fingerprint == hint.fingerprint } + hint)
                            .filter { now - it.seenAtWall <= HINT_TTL_MS }
                            .sortedBy(UdpMacHint::name)
                            .let { hints -> if (hints.size <= MAX_PEERS) hints else hints.sortedBy(UdpMacHint::seenAtWall).takeLast(MAX_PEERS) }
                    }
                } catch (_: SocketTimeoutException) {
                    Unit
                } catch (error: java.net.SocketException) {
                    if (isActive) throw error
                }
            }
        }
    }

    private fun parse(bytes: ByteArray, source: String, now: Long): UdpMacHint? = runCatching {
        val value = StrictJson.parseObject(bytes)
        if (value.string("type") != "eko_announce") return@runCatching null
        val port = value.integer("port")
        val fingerprint = (value.stringOrNull("fingerprint") ?: value.string("fp")).lowercase()
        if (port !in 1..65_535 || !FINGERPRINT.matches(fingerprint)) return@runCatching null
        UdpMacHint(source, port, value.string("name").take(128), fingerprint, now)
    }.getOrNull()

    private fun kotlinx.serialization.json.JsonObject.string(name: String): String {
        val value = this[name] as? JsonPrimitive ?: error("missing string")
        require(value.isString)
        return value.content
    }

    private fun kotlinx.serialization.json.JsonObject.stringOrNull(name: String): String? {
        val value = this[name] ?: return null
        val primitive = value as? JsonPrimitive ?: return null
        return primitive.content.takeIf { primitive.isString }
    }

    private fun kotlinx.serialization.json.JsonObject.integer(name: String): Int {
        val value = this[name] as? JsonPrimitive ?: error("missing integer")
        require(!value.isString)
        return value.intOrNull ?: error("invalid integer")
    }

    override fun close() {
        job?.cancel()
        job = null
        socket?.close()
        socket = null
    }

    private companion object {
        const val PORT = 48_809
        const val MAX_PACKET_BYTES = 1_024
        const val MIN_PACKET_INTERVAL_MS = 500L
        const val MIN_GLOBAL_PACKET_INTERVAL_MS = 50L
        const val MAX_PEERS = 42
        const val HINT_TTL_MS = 15_000L
        val FINGERPRINT = Regex("^[0-9a-f]{64}$")
    }
}
