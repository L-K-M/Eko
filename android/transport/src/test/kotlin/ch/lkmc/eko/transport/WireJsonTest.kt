package dev.eko.transport

import dev.eko.core.AppDescriptor
import dev.eko.core.DndDescriptor
import dev.eko.core.DurableEventBody
import dev.eko.core.EkoJson
import dev.eko.core.EventKind
import dev.eko.core.NotificationContent
import dev.eko.core.ProtocolException
import dev.eko.outbox.BacklogSnapshot
import dev.eko.outbox.GapSpanEntity
import dev.eko.outbox.OutboxEventEntity
import kotlinx.serialization.encodeToString
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class WireJsonTest {
    @Test
    fun `event overlays replay metadata without mutating durable payload`() {
        val body = DurableEventBody(
            event = EventKind.POSTED,
            key = "opaque-key",
            postedAt = 12,
            user = 0,
            app = AppDescriptor("example.app", "Example", "msg"),
            notification = NotificationContent(text = "Code 123456", isClearable = true, isGroupSummary = false),
            dnd = DndDescriptor("all", false),
        )
        val entity = OutboxEventEntity(
            seq = 7,
            notificationKey = requireNotNull(body.key),
            eventType = "posted",
            payloadJson = EkoJson.encodeToString(body),
            contentHash = "ab".repeat(32),
            createdWall = 1,
            createdElapsed = 1,
            createdBoot = "boot",
        )

        val replay = WireJson.event(entity, replayed = true, syncId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
        val live = WireJson.event(entity, replayed = false)

        assertEquals(7, replay.strictLong("seq"))
        assertTrue(replay["flags"].toString().contains("\"replayed\":true"))
        assertEquals("aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", replay.strictString("sync_id"))
        assertFalse(live["flags"].toString().contains("\"replayed\":true"))
        assertEquals("ab".repeat(32), replay.strictString("h"))
    }

    @Test
    fun `strict integer validator rejects quoted values and overflow`() {
        assertThrows(ProtocolException::class.java) {
            EkoJson.parseToJsonElement("""{"seq":"4"}""").let { it as kotlinx.serialization.json.JsonObject }.strictLong("seq")
        }
        assertThrows(ProtocolException::class.java) {
            EkoJson.parseToJsonElement("""{"seq":999999999999999999999999}""").let { it as kotlinx.serialization.json.JsonObject }.strictLong("seq")
        }
    }

    @Test
    fun `store reset error frame matches the protocol error catalog`() {
        val frame = WireJson.error("store_reset")

        assertEquals("error", frame.strictString("type"))
        assertEquals("store_reset", frame.strictString("code"))
        assertTrue(frame.strictBoolean("fatal"))
    }

    @Test
    fun `backlog frames carry exact sequence coverage`() {
        val body = DurableEventBody(
            event = EventKind.POSTED,
            key = "opaque-key",
            postedAt = 12,
            user = 0,
            app = AppDescriptor("example.app", "Example", "msg"),
            notification = NotificationContent(text = "redacted", isClearable = true, isGroupSummary = false),
            dnd = DndDescriptor("all", false),
        )
        val event = OutboxEventEntity(
            seq = 43,
            notificationKey = requireNotNull(body.key),
            eventType = "posted",
            payloadJson = EkoJson.encodeToString(body),
            contentHash = "ab".repeat(32),
            createdWall = 1,
            createdElapsed = 1,
            createdBoot = "boot",
        )
        val snapshot = BacklogSnapshot(
            generation = "generation",
            highWater = 43,
            replayFromSeq = 43,
            eventSeqs = listOf(43),
            gaps = listOf(GapSpanEntity("peer", "generation", 41, 42, "retention_count")),
            active = emptyList(),
        )

        val frames =
            WireJson.backlogStart(snapshot, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee") +
                WireJson.backlogEvent(event, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee") +
                WireJson.backlogEnd(snapshot, "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")

        assertEquals(
            listOf(null, SequenceCoverage(41, 42), SequenceCoverage(43, 43), null, null),
            frames.map(OutboundFrame::coverage),
        )
        assertEquals(
            listOf("backlog_start", "backlog_gap", "event", "active_chunk", "backlog_end"),
            frames.map { it.message.strictString("type") },
        )
        val start = frames.first()
        assertEquals(1, start.message.strictLong("event_count"))
    }
}
