package dev.eko.core

import java.io.ByteArrayInputStream
import java.io.EOFException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith

class FrameCodecTest {
    @Test
    fun `round trips partial stream reads`() {
        val encoded = FrameCodec.encodeJson("""{"type":"ping","phone_time":42}""")
        val frame = FrameCodec.read(ChunkedInputStream(encoded, maxChunk = 1))

        assertEquals(JSON_FRAME_TYPE, frame?.type)
        assertContentEquals("""{"type":"ping","phone_time":42}""".encodeToByteArray(), frame?.payload)
    }

    @Test
    fun `length includes frame type`() {
        val encoded = FrameCodec.encode(Frame(BINARY_FRAME_TYPE, byteArrayOf(1, 2, 3)))
        assertEquals(4, ByteBuffer.wrap(encoded, 0, 4).order(ByteOrder.BIG_ENDIAN).int)
    }

    @Test
    fun `rejects zero and oversized lengths before allocation`() {
        assertFailsWith<ProtocolException> {
            FrameCodec.read(ByteArrayInputStream(byteArrayOf(0, 0, 0, 0)))
        }
        val tooLarge = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(MAX_FRAME_LENGTH + 1).array()
        assertFailsWith<ProtocolException> { FrameCodec.read(ByteArrayInputStream(tooLarge)) }
    }

    @Test
    fun `rejects truncated frames`() {
        val encoded = FrameCodec.encodeJson("{}")
        assertFailsWith<EOFException> {
            FrameCodec.read(ByteArrayInputStream(encoded.copyOf(encoded.size - 1)))
        }
    }

    @Test
    fun `rejects invalid UTF-8 and duplicate keys`() {
        val invalidUtf8 = FrameCodec.encode(Frame(JSON_FRAME_TYPE, byteArrayOf(0xc3.toByte(), 0x28)))
        assertFailsWith<ProtocolException> { FrameCodec.readJson(ByteArrayInputStream(invalidUtf8)) }

        val duplicate = FrameCodec.encodeJson("""{"type":"ping","type":"pong"}""")
        assertFailsWith<ProtocolException> { FrameCodec.readJson(ByteArrayInputStream(duplicate)) }
    }

    @Test
    fun `skips unknown frame payload without interpreting it`() {
        val unknown = FrameCodec.encode(Frame(0x7f, ByteArray(128) { it.toByte() }))
        val next = FrameCodec.encodeJson("""{"type":"pong"}""")
        val stream = ByteArrayInputStream(unknown + next)

        assertEquals(0x7f, FrameCodec.read(stream)?.type)
        assertEquals("pong", FrameCodec.readJson(stream).requiredString("type"))
    }
}
