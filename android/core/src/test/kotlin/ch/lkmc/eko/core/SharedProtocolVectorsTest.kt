package dev.eko.core

import java.io.ByteArrayInputStream
import java.io.EOFException
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.reflect.KClass
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import kotlin.test.fail

class SharedProtocolVectorsTest {
    @Test
    fun `shared SAS vector matches commitments transcript and code`() {
        val root = resourceJson("sas.json")
        val attempt = root.string("attempt_id").hexBytes()
        val participants = root["participants"]!!.jsonObject
        val phone = participants["phone"]!!.jsonObject
        val mac = participants["mac"]!!.jsonObject
        val phoneCert = phone.string("cert_der_hex").hexBytes()
        val macCert = mac.string("cert_der_hex").hexBytes()
        val phoneNonce = phone.string("nonce_hex").hexBytes()
        val macNonce = mac.string("nonce_hex").hexBytes()

        assertEquals(phone.string("commitment"), Sas.commitment(attempt, phoneCert, phoneNonce).hexLower())
        assertEquals(mac.string("commitment"), Sas.commitment(attempt, macCert, macNonce).hexLower())
        val expected = root["expected"]!!.jsonObject
        assertEquals(expected.string("transcript_hash"), Sas.transcriptHash(attempt, phoneCert, phoneNonce, macCert, macNonce))
        assertEquals(expected.string("verification_code"), Sas.verificationCode(attempt, phoneCert, phoneNonce, macCert, macNonce))
    }

    @Test
    fun `shared concrete framing vectors decode byte exactly`() {
        val vectors = resourceJson("framing.json")["vectors"] as JsonArray
        vectors.map { it.jsonObject }.filter { "wire_hex" in it }.forEach { vector ->
            val wire = vector.string("wire_hex").hexBytes()
            val frame = FrameCodec.read(ByteArrayInputStream(wire))!!
            assertEquals(vector["frame_type"]!!.jsonPrimitive.content.toInt(), frame.type, vector.string("id"))
            vector["payload_utf8"]?.jsonPrimitive?.content?.let { expected ->
                assertContentEquals(expected.encodeToByteArray(), frame.payload, vector.string("id"))
            }
        }
    }

    @Test
    fun `shared malformed wire frames are rejected with the matching error class`() {
        val vectors = malformedVectors().filter { "wire_hex" in it["input"]!!.jsonObject }
        assertTrue(vectors.isNotEmpty())
        vectors.forEach { vector ->
            val id = vector.string("id")
            val expected: KClass<out Exception> = when (vector["expect"]!!.jsonObject.string("error")) {
                "length_zero", "frame_too_large", "invalid_json", "invalid_utf8", "utf8_bom" -> ProtocolException::class
                "incomplete_prefix", "incomplete_body" -> EOFException::class
                else -> fail("$id uses an unmapped wire error class")
            }
            val wire = vector["input"]!!.jsonObject.string("wire_hex").hexBytes()
            val error = assertFailsWith(expected, id) { FrameCodec.readJson(ByteArrayInputStream(wire)) }
            if (vector["expect"]!!.jsonObject.string("error") == "invalid_utf8") {
                assertTrue(error.message.orEmpty().contains("UTF-8"), id)
            }
        }
    }

    @Test
    fun `shared malformed json lexical frames are rejected by the strict reader`() {
        val lexicalErrors = setOf("trailing_json_data", "invalid_json", "top_level_not_object", "duplicate_member")
        val vectors = malformedVectors().filter {
            "payload_utf8" in it["input"]!!.jsonObject &&
                it["expect"]!!.jsonObject["error"]?.jsonPrimitive?.content in lexicalErrors
        }
        assertEquals(
            setOf("trailing-non-whitespace", "top-level-array", "duplicate-root-required-member", "duplicate-nested-member"),
            vectors.map { it.string("id") }.toSet(),
        )
        vectors.forEach { vector ->
            val id = vector.string("id")
            val expect = vector["expect"]!!.jsonObject
            val input = vector["input"]!!.jsonObject
            val frameType = input["frame_type"]?.jsonPrimitive?.int ?: JSON_FRAME_TYPE
            val wire = FrameCodec.encode(Frame(frameType, input.string("payload_utf8").encodeToByteArray()))
            val error = assertFailsWith<ProtocolException>(id) { FrameCodec.readJson(ByteArrayInputStream(wire)) }
            when (expect.string("error")) {
                "trailing_json_data" -> assertTrue(error.message.orEmpty().contains("Trailing"), id)
                "top_level_not_object" -> assertTrue(error.message.orEmpty().contains("object"), id)
                "duplicate_member" -> assertTrue(error.message.orEmpty().contains("'${expect.string("member")}'"), id)
            }
        }
    }

    private fun malformedVectors(): List<JsonObject> =
        (resourceJson("malformed-frames.json")["vectors"] as JsonArray).map { it.jsonObject }

    private fun resourceJson(name: String): JsonObject {
        val content = requireNotNull(javaClass.classLoader?.getResource(name)) { "Missing shared protocol vector $name" }.readText()
        return EkoJson.parseToJsonElement(content).jsonObject
    }

    private fun JsonObject.string(name: String): String = this[name]!!.jsonPrimitive.content
}
