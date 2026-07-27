package dev.eko.core

import java.io.ByteArrayInputStream
import java.io.EOFException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue

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
    fun `accepts objects and arrays at the 64 level nesting limit`() {
        val payloads = listOf(nestedObject(levels = 64), nestedArray(levels = 64))

        payloads.forEach { payload ->
            val parsed = FrameCodec.readJson(ByteArrayInputStream(FrameCodec.encodeJson(payload)))
            assertTrue("value" in parsed)
        }
    }

    @Test
    fun `rejects objects and arrays above the 64 level nesting limit`() {
        val payloads = listOf(nestedObject(levels = 65), nestedArray(levels = 65))

        payloads.forEach { payload ->
            val error = assertFailsWith<ProtocolException> {
                FrameCodec.readJson(ByteArrayInputStream(FrameCodec.encodeJson(payload)))
            }
            assertTrue(error.message.orEmpty().contains("nesting exceeds 64 levels"))
        }
    }

    @Test
    fun `rejects deeply nested JSON without overflowing the stack`() {
        val encoded = FrameCodec.encodeJson(nestedObject(levels = 10_000))

        assertFailsWith<ProtocolException> {
            FrameCodec.readJson(ByteArrayInputStream(encoded))
        }
    }

    @Test
    fun `skips unknown frame payload without interpreting it`() {
        val unknown = FrameCodec.encode(Frame(0x7f, ByteArray(128) { it.toByte() }))
        val next = FrameCodec.encodeJson("""{"type":"pong"}""")
        val stream = ByteArrayInputStream(unknown + next)

        assertEquals(0x7f, FrameCodec.read(stream)?.type)
        assertEquals("pong", FrameCodec.readJson(stream).requiredString("type"))
    }

    private fun nestedObject(levels: Int): String = buildString {
        repeat(levels) { append("{\"value\":") }
        append("null")
        repeat(levels) { append('}') }
    }

    private fun nestedArray(levels: Int): String = buildString {
        append("{\"value\":")
        repeat(levels - 1) { append('[') }
        append("null")
        repeat(levels - 1) { append(']') }
        append('}')
    }
}
