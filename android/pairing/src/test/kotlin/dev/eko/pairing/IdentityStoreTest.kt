package dev.eko.pairing

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import java.util.UUID
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class IdentityStoreTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val store = IdentityStore.get(context)

    @Test
    fun `connection epoch is durable and strictly monotonic`() = runTest {
        val first = store.nextConnectionEpoch()
        val second = IdentityStore.get(context).nextConnectionEpoch()

        assertEquals(first + 1, second)
        assertEquals(second, store.read().connectionEpoch)
    }

    @Test
    fun `pending pairing is idempotent and promotes only after both confirmations`() = runTest {
        val attempt = UUID.randomUUID().toString()
        val peerId = "a".repeat(64)
        val pending = PendingPairing(
            attemptId = attempt,
            peerDeviceId = peerId,
            peerName = "Mac",
            peerCertificateDerBase64 = "Y2VydA==",
            endpoint = PeerEndpoint("192.0.2.1", 48_808),
            transcriptHash = "b".repeat(64),
            outboxGeneration = UUID.randomUUID().toString(),
            expiresAtWall = System.currentTimeMillis() + 60_000,
            expiresAtElapsed = android.os.SystemClock.elapsedRealtime() + 60_000,
            bootCount = android.provider.Settings.Global.getInt(context.contentResolver, android.provider.Settings.Global.BOOT_COUNT, -1),
        )
        store.savePending(pending)
        store.savePending(pending)
        assertEquals(1, store.read().pendingPairings.count { it.attemptId == attempt })

        store.markLocalConfirmed(attempt)
        store.markPeerConfirmed(attempt)
        val peer = ConfirmedPeer(
            deviceId = peerId,
            name = "Mac",
            certificateDerBase64 = pending.peerCertificateDerBase64,
            endpoint = pending.endpoint,
            pairAttemptId = attempt,
            transcriptHash = requireNotNull(pending.transcriptHash),
            initialCursor = 12,
            pairedAtWall = System.currentTimeMillis(),
        )
        store.promotePending(attempt, peer)

        assertNotNull(store.read().confirmedPeers.firstOrNull { it.deviceId == peerId })
        assertNull(store.read().pendingPairings.firstOrNull { it.attemptId == attempt })
        store.revokeToTombstone(peerId)
        assertNotNull(store.read().tombstones.firstOrNull { it.deviceId == peerId })
        store.clearTombstone(peerId)
    }

    @Test
    fun `generation reset journal survives until explicit completion`() = runTest {
        store.pendingReset()?.let { store.completeReset(it.newGeneration) }
        val next = UUID.randomUUID().toString()
        val journal = store.beginReset("old", next)

        assertEquals(next, store.pendingReset()?.newGeneration)
        assertTrue(store.read().retiredGenerations.contains("old"))
        store.completeReset(journal.newGeneration)
        assertNull(store.pendingReset())
        assertEquals(next, store.read().currentGeneration)
    }

    @Test
    fun `tombstones and applied receipts keep the start gate open after process death`() = runTest {
        val peerId = "b".repeat(64)
        promotePeer(peerId)
        assertTrue(IdentityStore.hasKnownPeer(context))

        store.revokeToTombstone(peerId)
        assertTrue(store.read().confirmedPeers.isEmpty())
        assertTrue("a pending tombstone must keep unpair work restartable", IdentityStore.hasKnownPeer(context))

        store.applyRemoteUnpair(peerId, UUID.randomUUID().toString(), peerId, "c".repeat(64))
        store.clearTombstone(peerId)
        assertTrue("an undelivered receipt must keep unpair work restartable", IdentityStore.hasKnownPeer(context))

        store.clearAppliedReceipt(store.read().appliedUnpairReceipts.single().unpairId)
        assertEquals(false, IdentityStore.hasKnownPeer(context))
    }

    @Test
    fun `crossed simultaneous unpair applies from the tombstone and stays idempotent`() = runTest {
        val peerId = "d".repeat(64)
        val localId = "e".repeat(64)
        promotePeer(peerId)
        store.revokeToTombstone(peerId)

        val crossedId = UUID.randomUUID().toString()
        val receipt = store.applyRemoteUnpair(peerId, crossedId, peerId, localId)

        assertEquals(crossedId, receipt.unpairId)
        assertEquals(peerId, receipt.initiatorId)
        assertNotNull(
            "our own tombstone survives until its ack arrives",
            store.read().tombstones.firstOrNull { it.deviceId == peerId },
        )

        val retry = store.applyRemoteUnpair(peerId, crossedId, peerId, localId)
        assertEquals(receipt.unpairId, retry.unpairId)
        assertEquals(1, store.read().appliedUnpairReceipts.count { it.unpairId == crossedId })

        org.junit.Assert.assertThrows(IllegalStateException::class.java) {
            kotlinx.coroutines.runBlocking {
                store.applyRemoteUnpair("f".repeat(64), UUID.randomUUID().toString(), "f".repeat(64), localId)
            }
        }
    }

    private suspend fun promotePeer(peerId: String) {
        val attempt = UUID.randomUUID().toString()
        store.savePending(
            PendingPairing(
                attemptId = attempt,
                peerDeviceId = peerId,
                peerName = "Mac",
                peerCertificateDerBase64 = "Y2VydA==",
                endpoint = PeerEndpoint("192.0.2.1", 48_808),
                transcriptHash = "a".repeat(64),
                outboxGeneration = UUID.randomUUID().toString(),
                expiresAtWall = System.currentTimeMillis() + 60_000,
                expiresAtElapsed = android.os.SystemClock.elapsedRealtime() + 60_000,
                bootCount = android.provider.Settings.Global.getInt(context.contentResolver, android.provider.Settings.Global.BOOT_COUNT, -1),
            ),
        )
        store.markLocalConfirmed(attempt)
        store.markPeerConfirmed(attempt)
        store.promotePending(
            attempt,
            ConfirmedPeer(
                deviceId = peerId,
                name = "Mac",
                certificateDerBase64 = "Y2VydA==",
                endpoint = PeerEndpoint("192.0.2.1", 48_808),
                pairAttemptId = attempt,
                transcriptHash = "a".repeat(64),
                initialCursor = 0,
                pairedAtWall = System.currentTimeMillis(),
            ),
        )
    }
}
