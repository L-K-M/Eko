package dev.eko.transport

import dev.eko.core.ProtocolException
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.OutputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class OutboundActorTest {
    @Test
    fun `authorization advances over event and gap coverage`() = runTest {
        val output = object : OutputStream() {
            val buffer = ByteArrayOutputStream()
            override fun write(b: Int) = buffer.write(b)
            override fun write(b: ByteArray, off: Int, len: Int) {
                buffer.write(b, off, len)
            }
        }
        val actor = OutboundActor(this, output, initialAuthorizedThrough = 40)

        actor.send(buildJsonObject { put("type", "event") }, sequence = 41)

        assertEquals(41, actor.authorizedThrough())

        actor.sendFrames(
            listOf(
                OutboundFrame(
                    buildJsonObject { put("type", "event"); put("seq", 42) },
                    SequenceCoverage(42, 42),
                ),
                OutboundFrame(
                    buildJsonObject { put("type", "backlog_gap"); put("from_seq", 43); put("to_seq", 44) },
                    SequenceCoverage(43, 44),
                ),
            ),
        )
        assertEquals(44, actor.authorizedThrough())
        actor.close()
    }

    @Test
    fun `ack authorization waits for an in-progress write`() {
        runBlocking {
            val writeStarted = CountDownLatch(1)
            val releaseWrite = CountDownLatch(1)
            val scope = CoroutineScope(Job() + Dispatchers.IO)
            val actor = OutboundActor(scope, object : OutputStream() {
                override fun write(b: Int) = Unit
                override fun write(b: ByteArray, off: Int, len: Int) {
                    writeStarted.countDown()
                    check(releaseWrite.await(10, TimeUnit.SECONDS))
                }
            })

            val send = scope.async {
                actor.send(buildJsonObject { put("type", "event") }, sequence = 1)
            }
            try {
                assertTrue(writeStarted.await(10, TimeUnit.SECONDS))
                val authorization = async(start = CoroutineStart.UNDISPATCHED) { actor.authorizedThrough() }
                assertFalse(authorization.isCompleted)

                releaseWrite.countDown()
                send.await()
                assertEquals(1, authorization.await())
            } finally {
                releaseWrite.countDown()
                actor.close()
                scope.cancel()
            }
        }
    }

    @Test
    fun `failed frame does not authorize its position`() = runTest {
        var writes = 0
        val actor = OutboundActor(this, object : OutputStream() {
            override fun write(b: Int) = Unit
            override fun write(b: ByteArray, off: Int, len: Int) {
                writes += 1
                if (writes == 2) throw IOException("synthetic write failure")
            }
        })

        val error = runCatching {
            actor.sendFrames(
                listOf(
                    OutboundFrame(
                        buildJsonObject { put("type", "event"); put("seq", 1) },
                        SequenceCoverage(1, 1),
                    ),
                    OutboundFrame(
                        buildJsonObject { put("type", "event"); put("seq", 2) },
                        SequenceCoverage(2, 2),
                    ),
                ),
            )
        }.exceptionOrNull()
        assertTrue(error is IOException)
        assertEquals(1, actor.authorizedThrough())
        actor.close()
    }

    @Test
    fun `non-contiguous coverage is rejected before writing`() = runTest {
        val output = ByteArrayOutputStream()
        val actor = OutboundActor(this, output, initialAuthorizedThrough = 40)

        val error = runCatching {
            actor.send(buildJsonObject { put("type", "event") }, sequence = 42)
        }.exceptionOrNull()

        assertTrue(error is ProtocolException)
        assertEquals(0, output.size())
        assertEquals(40, actor.authorizedThrough())
        actor.close()
    }
}
