package dev.eko.core

import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals

class ContentHashTest {
    @Test
    fun `all shared content hash vectors canonicalize and hash`() {
        val vectors = resourceJson("content-hash.json")["vectors"] as JsonArray
        vectors.map { it.jsonObject }.forEach { vector ->
            val id = vector.string("id")
            val notification = EkoJson.decodeFromJsonElement<NotificationContent>(vector.getValue("n"))
            val canonical = CanonicalJson.encode(EkoJson.encodeToJsonElement(notification))
            assertEquals(vector.string("canonical_utf8"), String(canonical, Charsets.UTF_8), id)
            assertEquals(vector.string("canonical_utf8_hex"), canonical.hexLower(), id)
            assertEquals(vector.string("sha256"), sha256(canonical).hexLower(), id)
        }
    }

    private fun resourceJson(name: String): JsonObject {
        val content = requireNotNull(javaClass.classLoader?.getResource(name)) { "Missing shared protocol vector $name" }.readText()
        return EkoJson.parseToJsonElement(content).jsonObject
    }

    private fun JsonObject.string(name: String): String = this[name]!!.jsonPrimitive.content
}
