package dev.eko.transport

import dev.eko.pairing.ConfirmedPeer
import dev.eko.pairing.IdentityState

internal data class PeerJobPlan(
    val startPeers: List<ConfirmedPeer>,
    val stopPeerIds: List<String>,
    val markPausedIds: List<String>,
)

internal fun planPeerJobs(
    state: IdentityState,
    activePeerJobIds: Set<String>,
    resetInProgress: Boolean,
): PeerJobPlan {
    val confirmedIds = state.confirmedPeers.map(ConfirmedPeer::deviceId).toSet()
    val receiptPeerIds = state.appliedUnpairReceipts.map { it.deviceId }.toSet()
    if (state.forwardingPaused || resetInProgress) {
        return PeerJobPlan(
            startPeers = emptyList(),
            stopPeerIds = activePeerJobIds.filterNot { it in receiptPeerIds },
            markPausedIds = if (state.forwardingPaused && !resetInProgress) confirmedIds.toList() else emptyList(),
        )
    }
    return PeerJobPlan(
        startPeers = state.confirmedPeers.filterNot { it.deviceId in activePeerJobIds },
        stopPeerIds = activePeerJobIds.filterNot { it in confirmedIds || it in receiptPeerIds },
        markPausedIds = emptyList(),
    )
}
