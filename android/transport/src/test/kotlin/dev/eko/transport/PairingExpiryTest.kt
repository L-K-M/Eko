package dev.eko.transport

import android.content.Context
import android.os.SystemClock
import androidx.test.core.app.ApplicationProvider
import dev.eko.core.FrameCodec
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.PairingCoordinator
import dev.eko.pairing.PeerEndpoint
import dev.eko.pairing.PendingPairing
import java.net.ServerSocket
import java.net.Socket
import java.util.UUID
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class PairingExpiryTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()
    private val store = IdentityStore.get(context)
    private val coordinator = PairingCoordinator(context)

    @Test
    fun `confirm after the absolute expiry rejects the attempt without peer input`() = runTest {
        val attempt = persistPending()
        val handle = handle(attempt, expiresAtElapsed = SystemClock.elapsedRealtime() - 1)

        val result = handle.confirm(true)

        assertNull(result)
        assertTrue(handle.isExpired)
        assertNull(store.read().pendingPairings.firstOrNull { it.attemptId == attempt })
    }

    @Test
    fun `expire while the verification UI is open blocks a late confirm`() = runTest {
        val attempt = persistPending()
        val handle = handle(attempt, expiresAtElapsed = SystemClock.elapsedRealtime() + 60_000)
        assertFalse(handle.isExpired)

        handle.expire()

        assertTrue(handle.isExpired)
        assertNull(handle.confirm(true))
        assertNull(store.read().pendingPairings.firstOrNull { it.attemptId == attempt })
    }

    @Test
    fun `live attempt can still send its rejection before expiry`() = runTest {
        val attempt = persistPending()
        val server = ServerSocket(0)
        val client = Socket(server.inetAddress, server.localPort)
        val accepted = server.accept()
        try {
            val handle = handle(attempt, SystemClock.elapsedRealtime() + 60_000, client)

            assertNull(handle.confirm(false))

            val frame = FrameCodec.readJson(accepted.getInputStream())
            assertEquals("pair_result", frame.strictString("type"))
            assertEquals("reject", frame.strictString("result"))
            assertNull(store.read().pendingPairings.firstOrNull { it.attemptId == attempt })
        } finally {
            runCatching { client.close() }
            runCatching { accepted.close() }
            server.close()
        }
    }

    private suspend fun persistPending(): String {
        val attempt = UUID.randomUUID().toString()
        store.savePending(
            PendingPairing(
                attemptId = attempt,
                peerDeviceId = "a".repeat(64),
                peerName = "Mac",
                peerCertificateDerBase64 = "Y2VydA==",
                endpoint = PeerEndpoint("192.0.2.1", 48_808),
                transcriptHash = "b".repeat(64),
                outboxGeneration = UUID.randomUUID().toString(),
                expiresAtWall = System.currentTimeMillis() + 60_000,
                expiresAtElapsed = SystemClock.elapsedRealtime() + 60_000,
                bootCount = android.provider.Settings.Global.getInt(context.contentResolver, android.provider.Settings.Global.BOOT_COUNT, -1),
            ),
        )
        assertNotNull(store.read().pendingPairings.firstOrNull { it.attemptId == attempt })
        return attempt
    }

    private fun handle(attempt: String, expiresAtElapsed: Long, socket: Socket = Socket()) = PairingHandle(
        verificationCode = "ABCD1234",
        attemptId = attempt,
        peerName = "Mac",
        expiresAtElapsed = expiresAtElapsed,
        localDeviceId = "b".repeat(64),
        peerDeviceId = "a".repeat(64),
        socket = socket,
        transcriptHash = "b".repeat(64),
        coordinator = coordinator,
    )
}
