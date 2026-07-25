package dev.eko.transport

import dev.eko.core.ProtocolException
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionInboundValidatorTest {
    private val peerId = "a".repeat(64)
    private val localId = "b".repeat(64)
    private val fullCaps = SessionInboundValidator(setOf("notif", "dismiss", "otp_context"), peerId, localId)

    @Test
    fun `dismiss requires the negotiated dismiss capability`() {
        val message = buildJsonObject {
            put("type", "dismiss")
            put("key", "0|com.example|1|null")
        }

        val without = SessionInboundValidator(setOf("notif"), peerId, localId)
        assertThrows(ProtocolException::class.java) { without.validate(message) }
        assertEquals(InboundControl.Dismiss("0|com.example|1|null"), fullCaps.validate(message))
    }

    @Test
    fun `unknown types are ignored only with negotiated ext_types`() {
        val message = buildJsonObject { put("type", "future_control") }
        val extensible = SessionInboundValidator(setOf("notif", "ext_types"), peerId, localId)

        assertThrows(ProtocolException::class.java) { fullCaps.validate(message) }
        assertEquals(InboundControl.Ignored, extensible.validate(message))
    }

    @Test
    fun `known frames invalid in live state stay fatal even with ext_types`() {
        val extensible = SessionInboundValidator(setOf("notif", "ext_types"), peerId, localId)
        listOf("welcome", "hello", "event", "backlog_end", "ping", "pair_commit", "unpair_ack", "fetch_missing")
            .forEach { type ->
                assertThrows(type, ProtocolException::class.java) {
                    extensible.validate(buildJsonObject { put("type", type) })
                }
            }
    }

    @Test
    fun `fetch enforces key count uniqueness and shape`() {
        fun fetch(keys: List<String>) = buildJsonObject {
            put("type", "fetch")
            put("request_id", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
            putJsonArray("keys") { keys.forEach { add(kotlinx.serialization.json.JsonPrimitive(it)) } }
        }

        assertThrows(ProtocolException::class.java) { fullCaps.validate(fetch(emptyList())) }
        assertThrows(ProtocolException::class.java) { fullCaps.validate(fetch(listOf("k", "k"))) }
        assertThrows(ProtocolException::class.java) { fullCaps.validate(fetch((1..129).map { "k$it" })) }
        assertThrows(ProtocolException::class.java) { fullCaps.validate(fetch(listOf(""))) }

        val control = fullCaps.validate(fetch(listOf("k1", "k2")))
        assertEquals(InboundControl.Fetch("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", listOf("k1", "k2")), control)
    }

    @Test
    fun `ack and pong require canonical integers and uuid identifiers`() {
        assertThrows(ProtocolException::class.java) {
            fullCaps.validate(buildJsonObject {
                put("type", "ack")
                put("seq", "41")
            })
        }
        assertEquals(
            InboundControl.Ack(41),
            fullCaps.validate(buildJsonObject {
                put("type", "ack")
                put("seq", 41)
            }),
        )
        assertThrows(ProtocolException::class.java) {
            fullCaps.validate(buildJsonObject {
                put("type", "pong")
                put("ping_id", "not-a-uuid")
                put("phone_time", 1)
                put("mac_time", 2)
            })
        }
    }

    @Test
    fun `unpair is bound to the authenticated identities`() {
        fun unpair(initiator: String, peer: String) = buildJsonObject {
            put("type", "unpair")
            put("unpair_id", "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
            put("initiator_id", initiator)
            put("peer_id", peer)
            put("reason", "user_request")
        }

        assertThrows(ProtocolException::class.java) { fullCaps.validate(unpair(localId, peerId)) }
        assertThrows(ProtocolException::class.java) { fullCaps.validate(unpair(peerId, peerId)) }
        assertEquals(
            InboundControl.Unpair("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", peerId, localId),
            fullCaps.validate(unpair(peerId, localId)),
        )
    }

    @Test
    fun `error frames expose the fatal flag`() {
        val fatal = fullCaps.validate(buildJsonObject {
            put("type", "error")
            put("code", "superseded")
            put("fatal", true)
        })
        assertEquals(InboundControl.ErrorFrame("superseded", true), fatal)

        val advisory = fullCaps.validate(buildJsonObject {
            put("type", "error")
            put("code", "note")
            put("fatal", false)
        })
        assertTrue(advisory is InboundControl.ErrorFrame && !advisory.fatal)
    }
}
