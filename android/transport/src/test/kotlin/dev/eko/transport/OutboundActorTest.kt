package dev.eko.transport

import java.io.ByteArrayOutputStream
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Test

class OutboundActorTest {
    @Test
    fun `highest authorized is published before frames hit the wire`() = runTest {
        val authorized = AtomicLong(0)
        val observedDuringWrites = mutableListOf<Long>()
        val output = object : OutputStream() {
            val buffer = ByteArrayOutputStream()
            override fun write(b: Int) = buffer.write(b)
            override fun write(b: ByteArray, off: Int, len: Int) {
                observedDuringWrites += authorized.get()
                buffer.write(b, off, len)
            }
        }
        val actor = OutboundActor(this, output, authorized)

        actor.send(buildJsonObject { put("type", "event") }, authorizedThrough = 41)

        assertEquals(listOf(41L), observedDuringWrites)
        assertEquals(41, authorized.get())

        actor.sendBatch(
            listOf(buildJsonObject { put("type", "event") }, buildJsonObject { put("type", "event") }),
            authorizedThrough = 42,
        )
        assertEquals(listOf(41L, 42L, 42L), observedDuringWrites)
        actor.close()
    }
}
