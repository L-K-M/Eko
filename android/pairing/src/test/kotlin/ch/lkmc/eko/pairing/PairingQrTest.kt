package dev.eko.pairing

import dev.eko.core.ProtocolException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingQrTest {
    @Test
    fun `parses bounded authenticated endpoint payload`() {
        val payload = PairingQr.parse(
            """{"host":"192.0.2.5","port":48808,"certFingerprint":"${"ab".repeat(32)}","oneTimeToken":"${"a".repeat(43)}"}""",
        )

        assertEquals(PeerEndpoint("192.0.2.5", 48_808), payload.endpoint)
        assertEquals("ab".repeat(32), payload.certificateFingerprint)
        assertEquals("a".repeat(43), payload.token)
    }

    @Test
    fun `rejects an unpinned or malformed payload`() {
        assertThrows(ProtocolException::class.java) {
            PairingQr.parse("""{"host":"mac.local","port":48808,"token":"${"a".repeat(43)}"}""")
        }
        assertThrows(IllegalArgumentException::class.java) {
            PairingQr.parse("""{"host":"mac.local","port":48808,"certFingerprint":"bad","token":"${"a".repeat(43)}"}""")
        }
    }
}
