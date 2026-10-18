package dev.eko.transport

import dev.eko.pairing.AppliedUnpairReceipt
import dev.eko.pairing.ConfirmedPeer
import dev.eko.pairing.IdentityState
import dev.eko.pairing.PeerEndpoint
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class PeerJobPlannerTest {
    @Test
    fun `pause stops existing sessions promptly and prevents new sends`() {
        val state = IdentityState(
            confirmedPeers = listOf(peer("a"), peer("b")),
            forwardingPaused = true,
        )

        val plan = planPeerJobs(state, activePeerJobIds = setOf("a", "b"), resetInProgress = false)

        assertEquals(emptyList<ConfirmedPeer>(), plan.startPeers)
        assertEquals(setOf("a", "b"), plan.stopPeerIds.toSet())
        assertEquals(setOf("a", "b"), plan.markPausedIds.toSet())
    }

    @Test
    fun `resume starts peers that pause stopped`() {
        val state = IdentityState(confirmedPeers = listOf(peer("a"), peer("b")))

        val plan = planPeerJobs(state, activePeerJobIds = emptySet(), resetInProgress = false)

        assertEquals(setOf("a", "b"), plan.startPeers.map { it.deviceId }.toSet())
        assertEquals(emptyList<String>(), plan.stopPeerIds)
    }

    @Test
    fun `generation reset stops confirmed sessions and blocks starts`() {
        val state = IdentityState(confirmedPeers = listOf(peer("a"), peer("b")))

        val plan = planPeerJobs(state, activePeerJobIds = setOf("a"), resetInProgress = true)

        assertEquals(emptyList<ConfirmedPeer>(), plan.startPeers)
        assertEquals(listOf("a"), plan.stopPeerIds)
        assertEquals(emptyList<String>(), plan.markPausedIds)
    }

    @Test
    fun `receipt peer sessions are retained so their ack can flush`() {
        val receipt = AppliedUnpairReceipt(
            deviceId = "a",
            certificateDerBase64 = "Y2VydA==",
            endpoint = PeerEndpoint("192.0.2.1", 48_808),
            unpairId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
            initiatorId = "b".repeat(64),
            peerId = "c".repeat(64),
            appliedAtWall = 1,
        )
        val paused = IdentityState(appliedUnpairReceipts = listOf(receipt), forwardingPaused = true)
        val active = IdentityState(appliedUnpairReceipts = listOf(receipt))

        assertEquals(emptyList<String>(), planPeerJobs(paused, setOf("a"), false).stopPeerIds)
        assertEquals(emptyList<String>(), planPeerJobs(active, setOf("a"), false).stopPeerIds)
    }

    @Test
    fun `stale sessions for forgotten peers are stopped`() {
        val state = IdentityState(confirmedPeers = listOf(peer("a")))

        val plan = planPeerJobs(state, activePeerJobIds = setOf("a", "gone"), resetInProgress = false)

        assertEquals(listOf("gone"), plan.stopPeerIds)
        assertEquals(emptyList<ConfirmedPeer>(), plan.startPeers)
    }

    private fun peer(id: String) = ConfirmedPeer(
        deviceId = id,
        name = "Mac $id",
        certificateDerBase64 = "Y2VydA==",
        endpoint = PeerEndpoint("192.0.2.1", 48_808),
        pairAttemptId = "attempt-$id",
        transcriptHash = "a".repeat(64),
        initialCursor = 0,
        pairedAtWall = 1,
    )
}
