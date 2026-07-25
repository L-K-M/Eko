package dev.eko.core

import java.io.ByteArrayOutputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import kotlinx.serialization.json.JsonObject

data class Frame(val type: Int, val payload: ByteArray)

object FrameCodec {
    fun encode(frame: Frame): ByteArray {
        val length = frame.payload.size.toLong() + 1L
        if (length !in 1..MAX_FRAME_LENGTH.toLong()) {
            throw ProtocolException("Frame length $length is outside the allowed range")
        }
        return ByteBuffer.allocate(frame.payload.size + 5)
            .order(ByteOrder.BIG_ENDIAN)
            .putInt(length.toInt())
            .put(frame.type.toByte())
            .put(frame.payload)
            .array()
    }

    fun encodeJson(json: String): ByteArray = encode(
        Frame(JSON_FRAME_TYPE, json.toByteArray(StandardCharsets.UTF_8)),
    )

    fun write(output: OutputStream, frame: Frame) {
        output.write(encode(frame))
        output.flush()
    }

    fun read(input: InputStream): Frame? {
        val first = input.read()
        if (first == -1) return null
        val prefix = ByteArray(4)
        prefix[0] = first.toByte()
        readExact(input, prefix, 1, 3)
        val length = ByteBuffer.wrap(prefix).order(ByteOrder.BIG_ENDIAN).int
        if (length !in 1..MAX_FRAME_LENGTH) {
            throw ProtocolException("Frame length $length is outside the allowed range")
        }
        val bytes = ByteArray(length)
        readExact(input, bytes, 0, length)
        return Frame(bytes[0].toInt() and 0xff, bytes.copyOfRange(1, bytes.size))
    }

    fun readJson(input: InputStream): JsonObject {
        while (true) {
            val frame = read(input) ?: throw EOFException("Connection closed before a JSON frame")
            if (frame.type == JSON_FRAME_TYPE) return StrictJson.parseObject(frame.payload)
        }
    }

    private fun readExact(input: InputStream, target: ByteArray, offset: Int, count: Int) {
        var cursor = offset
        val end = offset + count
        while (cursor < end) {
            val read = input.read(target, cursor, end - cursor)
            if (read == -1) throw EOFException("Stream ended in the middle of a frame")
            if (read == 0) continue
            cursor += read
        }
    }
}

object StrictJson {
    fun parseObject(bytes: ByteArray): JsonObject {
        val text = try {
            StandardCharsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(ByteBuffer.wrap(bytes))
                .toString()
        } catch (error: Exception) {
            throw ProtocolException("JSON frame is not valid UTF-8", error)
        }
        JsonSyntaxScanner(text).validate()
        val value = try {
            EkoJson.parseToJsonElement(text)
        } catch (error: Exception) {
            throw ProtocolException("Malformed JSON frame", error)
        }
        return value as? JsonObject ?: throw ProtocolException("JSON frame must contain an object")
    }
}

private class JsonSyntaxScanner(private val source: String) {
    private var index = 0

    fun validate() {
        skipWhitespace()
        parseValue()
        skipWhitespace()
        if (index != source.length) fail("Trailing JSON content")
    }

    private fun parseValue() {
        skipWhitespace()
        when (source.getOrNull(index)) {
            '{' -> parseObject()
            '[' -> parseArray()
            '"' -> parseString()
            't' -> consumeLiteral("true")
            'f' -> consumeLiteral("false")
            'n' -> consumeLiteral("null")
            '-', in '0'..'9' -> parseNumber()
            else -> fail("Expected JSON value")
        }
    }

    private fun parseObject() {
        index++
        skipWhitespace()
        if (consumeIf('}')) return
        val keys = mutableSetOf<String>()
        while (true) {
            skipWhitespace()
            if (source.getOrNull(index) != '"') fail("Expected object key")
            val key = parseString()
            if (!keys.add(key)) throw ProtocolException("Duplicate JSON key '$key'")
            skipWhitespace()
            requireChar(':')
            parseValue()
            skipWhitespace()
            if (consumeIf('}')) return
            requireChar(',')
        }
    }

    private fun parseArray() {
        index++
        skipWhitespace()
        if (consumeIf(']')) return
        while (true) {
            parseValue()
            skipWhitespace()
            if (consumeIf(']')) return
            requireChar(',')
        }
    }

    private fun parseString(): String {
        requireChar('"')
        val result = StringBuilder()
        while (index < source.length) {
            val character = source[index++]
            when {
                character == '"' -> return result.toString()
                character == '\\' -> {
                    val escaped = source.getOrNull(index++) ?: fail("Incomplete escape")
                    when (escaped) {
                        '"', '\\', '/' -> result.append(escaped)
                        'b' -> result.append('\b')
                        'f' -> result.append('\u000c')
                        'n' -> result.append('\n')
                        'r' -> result.append('\r')
                        't' -> result.append('\t')
                        'u' -> {
                            if (index + 4 > source.length) fail("Incomplete unicode escape")
                            val code = source.substring(index, index + 4).toIntOrNull(16)
                                ?: fail("Invalid unicode escape")
                            result.append(code.toChar())
                            index += 4
                        }
                        else -> fail("Invalid string escape")
                    }
                }
                character.code < 0x20 -> fail("Control character in string")
                else -> result.append(character)
            }
        }
        fail("Unterminated string")
    }

    private fun parseNumber() {
        consumeIf('-')
        if (consumeIf('0')) {
            if (source.getOrNull(index) in '0'..'9') fail("Leading zero in number")
        } else {
            requireDigits()
        }
        if (consumeIf('.')) requireDigits()
        if (source.getOrNull(index) == 'e' || source.getOrNull(index) == 'E') {
            index++
            if (source.getOrNull(index) == '+' || source.getOrNull(index) == '-') index++
            requireDigits()
        }
    }

    private fun requireDigits() {
        val start = index
        while (source.getOrNull(index) in '0'..'9') index++
        if (start == index) fail("Expected number digits")
    }

    private fun consumeLiteral(literal: String) {
        if (!source.startsWith(literal, index)) fail("Invalid JSON literal")
        index += literal.length
    }

    private fun requireChar(expected: Char) {
        if (!consumeIf(expected)) fail("Expected '$expected'")
    }

    private fun consumeIf(expected: Char): Boolean {
        if (source.getOrNull(index) != expected) return false
        index++
        return true
    }

    private fun skipWhitespace() {
        while (source.getOrNull(index) == ' ' || source.getOrNull(index) == '\n' ||
            source.getOrNull(index) == '\r' || source.getOrNull(index) == '\t'
        ) index++
    }

    private fun fail(message: String): Nothing =
        throw ProtocolException("$message at character $index")
}

class ChunkedInputStream(
    private val bytes: ByteArray,
    private val maxChunk: Int,
) : InputStream() {
    private var offset = 0

    override fun read(): Int = if (offset >= bytes.size) -1 else bytes[offset++].toInt() and 0xff

    override fun read(target: ByteArray, targetOffset: Int, length: Int): Int {
        if (offset >= bytes.size) return -1
        val count = minOf(length, maxChunk, bytes.size - offset)
        bytes.copyInto(target, targetOffset, offset, offset + count)
        offset += count
        return count
    }
}
