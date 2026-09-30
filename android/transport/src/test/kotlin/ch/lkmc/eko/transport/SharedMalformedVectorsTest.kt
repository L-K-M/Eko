package dev.eko.transport

import dev.eko.core.EkoJson
import dev.eko.core.ProtocolException
import dev.eko.core.StrictJson
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class SharedMalformedVectorsTest {
    private val peerId = "a".repeat(64)
    private val localId = "b".repeat(64)

    @Test
    fun `shared context-based malformed cases are enforced by the inbound validator`() {
        val expected = setOf(
            "unknown-json-type-without-capability",
            "unknown-json-type-with-extension-capability",
            "ack-before-hello",
            "welcome-in-restricted-unpair",
            "replayed-event-missing-sync-id",
            "live-event-illegally-has-sync-id",
        )
        val root = resourceJson("malformed-frames.json")
        val vectors = (root["vectors"] as JsonArray).map { it.jsonObject }.filter { it.string("id") in expected }
        assertEquals(expected, vectors.map { it.string("id") }.toSet())

        vectors.forEach { vector ->
            val id = vector.string("id")
            val context = vector["context"]?.jsonObject
            val capabilities = context?.get("negotiated_caps")?.let { caps ->
                (caps as JsonArray).map { it.jsonPrimitive.content }.toSet()
            }.orEmpty()
            val state = when (val name = context?.get("connection_state")?.jsonPrimitive?.content) {
                null -> SessionState.ESTABLISHED
                "await_hello" -> SessionState.AWAIT_HELLO
                "restricted_unpair" -> SessionState.RESTRICTED_UNPAIR
                else -> throw AssertionError("$id uses unmapped connection state $name")
            }
            val validator = SessionInboundValidator(capabilities, peerId, localId, state)
            val payload = vector["input"]!!.jsonObject.string("payload_utf8")
            val message = StrictJson.parseObject(payload.encodeToByteArray())

            when (vector["expect"]!!.jsonObject.string("action")) {
                "close" -> assertThrows(id, ProtocolException::class.java) { validator.validate(message) }
                "ignore" -> assertEquals(id, InboundControl.Ignored, validator.validate(message))
                else -> throw AssertionError("$id uses an unmapped expected action")
            }
        }
    }

    private fun resourceJson(name: String): JsonObject {
        val content = requireNotNull(javaClass.classLoader?.getResource(name)) { "Missing shared protocol vector $name" }.readText()
        return EkoJson.parseToJsonElement(content).jsonObject
    }

    private fun JsonObject.string(name: String): String = this[name]!!.jsonPrimitive.content
}
