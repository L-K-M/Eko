package dev.eko.transport

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

sealed interface PeerTransportState {
    data object Offline : PeerTransportState
    data object WaitingForNetwork : PeerTransportState
    data class Reconnecting(val attempt: Int, val nextDelayMillis: Long) : PeerTransportState
    data class Syncing(val eventCount: Int) : PeerTransportState
    data class Connected(val sinceWall: Long, val acknowledgedThrough: Long) : PeerTransportState
    data object Paused : PeerTransportState
    data class Failed(val reason: String) : PeerTransportState
}

data class TransportSnapshot(
    val serviceRunning: Boolean = false,
    val peers: Map<String, PeerTransportState> = emptyMap(),
    val recentLog: List<String> = emptyList(),
    val lastForwardWall: Map<String, Long> = emptyMap(),
)

object TransportRuntime {
    private val mutable = MutableStateFlow(TransportSnapshot())
    val state = mutable.asStateFlow()

    fun running(value: Boolean) = update { it.copy(serviceRunning = value) }

    fun peer(deviceId: String, state: PeerTransportState) = update {
        it.copy(peers = it.peers + (deviceId to state))
    }

    fun removePeer(deviceId: String) = update {
        it.copy(peers = it.peers - deviceId, lastForwardWall = it.lastForwardWall - deviceId)
    }

    fun forwarded(deviceId: String) = update {
        it.copy(lastForwardWall = it.lastForwardWall + (deviceId to System.currentTimeMillis()))
    }

    fun log(message: String) = update {
        val line = "${System.currentTimeMillis()}: $message"
        it.copy(recentLog = (it.recentLog + line).takeLast(100))
    }

    // Peer jobs, the reconnect loop and log() all mutate this concurrently from
    // Dispatchers.IO. A read-modify-write on `.value` loses updates under that
    // contention — two peers transitioning at once drop one of the two states,
    // and log lines vanish. MutableStateFlow.update retries on conflict.
    private inline fun update(transform: (TransportSnapshot) -> TransportSnapshot) {
        mutable.update(transform)
    }
}
