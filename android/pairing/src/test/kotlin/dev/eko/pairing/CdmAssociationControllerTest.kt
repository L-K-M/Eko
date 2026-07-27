package dev.eko.pairing

import android.companion.CompanionDeviceManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.eko.core.EkoJson
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [32])
class CdmAssociationControllerTest {
    private val context = ApplicationProvider.getApplicationContext<Context>()

    @Test
    fun `BLE service UUID matches the shared discovery vector`() {
        val content = requireNotNull(javaClass.classLoader?.getResource("discovery.json")) {
            "Missing shared discovery vector"
        }.readText()
        val vector = EkoJson.parseToJsonElement(content).jsonObject
        val expected = vector.getValue("ble_service_uuid").jsonPrimitive.content

        assertEquals("eko-discovery-v1", vector.getValue("format").jsonPrimitive.content)
        assertEquals(expected, EKO_BLE_SERVICE_UUID.toString())
    }

    @Test
    fun `external association inventory changes are detected for listener rebind`() = runTest {
        val store = IdentityStore.get(context)
        val controller = CdmAssociationController(context, store)

        assertTrue(controller.reconcileInventory(listOf(AssociationRecord(id = 1, address = "AA:BB:CC:DD:EE:FF"))))
        assertFalse("an unchanged inventory must not trigger a rebind", controller.reconcileInventory(listOf(AssociationRecord(id = 1))))
        assertTrue("a revoked association is an external change", controller.reconcileInventory(emptyList()))
        assertFalse(controller.reconcileInventory(emptyList()))
    }

    @Test
    fun `last trust association is retained while any Mac remains paired`() = runTest {
        val store = IdentityStore.get(context)
        val controller = CdmAssociationController(context, store)
        val attempt = java.util.UUID.randomUUID().toString()
        store.savePending(
            PendingPairing(
                attemptId = attempt,
                peerDeviceId = "a".repeat(64),
                peerName = "Mac",
                peerCertificateDerBase64 = "Y2VydA==",
                endpoint = PeerEndpoint("192.0.2.1", 48_808),
                transcriptHash = "b".repeat(64),
                outboxGeneration = java.util.UUID.randomUUID().toString(),
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
                deviceId = "a".repeat(64),
                name = "Mac",
                certificateDerBase64 = "Y2VydA==",
                endpoint = PeerEndpoint("192.0.2.1", 48_808),
                pairAttemptId = attempt,
                transcriptHash = "b".repeat(64),
                initialCursor = 0,
                pairedAtWall = System.currentTimeMillis(),
            ),
        )
        controller.reconcileInventory(listOf(AssociationRecord(id = 7, address = "11:22:33:44:55:66")))

        assertFalse(controller.removeIfUnused(7))
        assertTrue(store.read().associations.single().pairingDependencies.contains("a".repeat(64)))

        store.revokeToTombstone("a".repeat(64))
        store.clearTombstone("a".repeat(64))
        Shadows.shadowOf(context.getSystemService(CompanionDeviceManager::class.java)).addAssociation("11:22:33:44:55:66")
        assertTrue(controller.removeIfUnused(7))
        assertTrue(store.read().associations.isEmpty())
    }

    @Test
    fun `system inventory drive-by triggers the after-mutation rebind once per change`() = runTest {
        val store = IdentityStore.get(context)
        var rebinds = 0
        val controller = CdmAssociationController(context, store) { rebinds += 1 }
        val shadow = Shadows.shadowOf(context.getSystemService(CompanionDeviceManager::class.java))
        shadow.addAssociation("AA:BB:CC:DD:EE:01")

        controller.inventory()
        assertEquals(1, rebinds)

        controller.inventory()
        assertEquals("an unchanged system inventory must not rebind again", 1, rebinds)

        shadow.addAssociation("AA:BB:CC:DD:EE:02")
        controller.inventory()
        assertEquals(2, rebinds)
    }
}
