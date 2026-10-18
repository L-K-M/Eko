package dev.eko.transport

import dev.eko.core.ProtocolException
import dev.eko.pairing.PeerEndpoint
import dev.eko.pairing.RevokedPeerTombstone
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TombstoneSessionTest {
    private val localId = "b".repeat(64)
    private val tombstone = RevokedPeerTombstone(
        deviceId = "a".repeat(64),
        certificateDerBase64 = "Y2VydA==",
        endpoint = PeerEndpoint("192.0.2.1", 48_808),
        createdAtWall = 1,
        unpairId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    )

    @Test
    fun `matching unpair ack completes the exchange`() {
        val ack = buildJsonObject {
            put("type", "unpair_ack")
            put("unpair_id", tombstone.unpairId)
            put("initiator_id", localId)
            put("peer_id", tombstone.deviceId)
            put("status", "applied")
        }

        assertEquals(TombstoneInbound.Acknowledged("applied"), parseTombstoneInbound(ack, tombstone, localId))
    }

    @Test
    fun `crossed simultaneous unpair request is accepted for acknowledgement`() {
        val crossed = buildJsonObject {
            put("type", "unpair")
            put("unpair_id", "cccccccc-dddd-4eee-8fff-000000000000")
            put("initiator_id", tombstone.deviceId)
            put("peer_id", localId)
            put("reason", "user_request")
        }

        assertEquals(
            TombstoneInbound.CrossedUnpair("cccccccc-dddd-4eee-8fff-000000000000", tombstone.deviceId, localId),
            parseTombstoneInbound(crossed, tombstone, localId),
        )
    }

    @Test
    fun `ack for a different unpair id is fatal`() {
        val ack = buildJsonObject {
            put("type", "unpair_ack")
            put("unpair_id", "cccccccc-dddd-4eee-8fff-000000000000")
            put("initiator_id", localId)
            put("peer_id", tombstone.deviceId)
            put("status", "applied")
        }

        assertThrows(ProtocolException::class.java) { parseTombstoneInbound(ack, tombstone, localId) }
    }

    @Test
    fun `crossed unpair with swapped identities is fatal`() {
        val crossed = buildJsonObject {
            put("type", "unpair")
            put("unpair_id", "cccccccc-dddd-4eee-8fff-000000000000")
            put("initiator_id", localId)
            put("peer_id", tombstone.deviceId)
            put("reason", "user_request")
        }

        assertThrows(ProtocolException::class.java) { parseTombstoneInbound(crossed, tombstone, localId) }
    }

    @Test
    fun `notification data and other frames are rejected in the restricted exchange`() {
        listOf("event", "welcome", "backlog_start", "ping", "pair_request").forEach { type ->
            assertThrows(type, ProtocolException::class.java) {
                parseTombstoneInbound(buildJsonObject { put("type", type) }, tombstone, localId)
            }
        }
    }

    @Test
    fun `fatal error frames close the exchange and advisory ones are diagnostics`() {
        assertThrows(ProtocolException::class.java) {
            parseTombstoneInbound(
                buildJsonObject {
                    put("type", "error")
                    put("code", "unpaired")
                    put("fatal", true)
                },
                tombstone,
                localId,
            )
        }
        assertEquals(
            TombstoneInbound.Diagnostic("note"),
            parseTombstoneInbound(
                buildJsonObject {
                    put("type", "error")
                    put("code", "note")
                    put("fatal", false)
                },
                tombstone,
                localId,
            ),
        )
    }
}
