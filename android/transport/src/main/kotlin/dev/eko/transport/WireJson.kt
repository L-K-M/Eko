package dev.eko.transport

import android.os.Build
import dev.eko.core.DurableEventBody
import dev.eko.core.EkoJson
import dev.eko.core.ProtocolException
import dev.eko.core.EventKind
import dev.eko.core.MAX_FRAME_LENGTH
import dev.eko.outbox.ActiveNotificationHeader
import dev.eko.outbox.BacklogSnapshot
import dev.eko.outbox.FetchRecord
import dev.eko.outbox.GapSpanEntity
import dev.eko.outbox.OutboxEventEntity
import dev.eko.pairing.DeviceIdentity
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.put

internal object WireJson {
    val capabilities = listOf("notif", "dismiss", "otp_context")

    fun helloNormal(
        identity: DeviceIdentity,
        generation: String,
        connectionEpoch: Long,
    ) = buildJsonObject {
        put("type", "hello")
        put("mode", "normal")
        put("proto_min", 1)
        put("proto_max", 1)
        put("device_id", identity.deviceId)
        put("device_name", "${Build.MANUFACTURER} ${Build.MODEL}".trim().take(256).ifBlank { "Android" })
        put("os", "android")
        put("os_version", Build.VERSION.SDK_INT)
        put("caps", strings(capabilities))
        put("outbox_gen", generation)
        put("conn_epoch", connectionEpoch)
        put("phone_time", System.currentTimeMillis())
    }

    fun helloUnpair(identity: DeviceIdentity, connectionEpoch: Long, unpairId: String) = buildJsonObject {
        put("type", "hello")
        put("mode", "unpair")
        put("proto_min", 1)
        put("proto_max", 1)
        put("device_id", identity.deviceId)
        put("device_name", "${Build.MANUFACTURER} ${Build.MODEL}".trim().take(256).ifBlank { "Android" })
        put("os", "android")
        put("os_version", Build.VERSION.SDK_INT)
        put("caps", JsonArray(emptyList()))
        put("conn_epoch", connectionEpoch)
        put("phone_time", System.currentTimeMillis())
        put("unpair_id", unpairId)
    }

    fun backlogStart(snapshot: BacklogSnapshot, syncId: String): List<OutboundFrame> = buildList {
        add(OutboundFrame(buildJsonObject {
            put("type", "backlog_start")
            put("sync_id", syncId)
            put("from_seq", snapshot.replayFromSeq)
            put("replay_to_seq", snapshot.highWater)
            put("event_count", snapshot.eventSeqs.size)
        }))
        snapshot.gaps.forEach { gap ->
            add(OutboundFrame(gap(gap, syncId), SequenceCoverage(gap.fromSeq, gap.toSeq)))
        }
    }

    fun backlogEnd(snapshot: BacklogSnapshot, syncId: String): List<OutboundFrame> = buildList {
        val activeChunks = boundedActiveChunks(syncId, snapshot.active)
        activeChunks.forEachIndexed { index, chunk ->
            add(OutboundFrame(activeChunk(syncId, index, chunk, index == activeChunks.lastIndex)))
        }
        add(OutboundFrame(buildJsonObject {
            put("type", "backlog_end")
            put("sync_id", syncId)
            put("state_seq", snapshot.highWater)
        }))
    }

    // One replayed event per frame; pages are assembled by the session from
    // EventRepository.replayPage so a long backlog never materializes at once.
    fun backlogEvent(entity: OutboxEventEntity, syncId: String): OutboundFrame =
        OutboundFrame(event(entity, replayed = true, syncId = syncId), SequenceCoverage(entity.seq, entity.seq))

    fun event(entity: OutboxEventEntity, replayed: Boolean, syncId: String? = null): JsonObject {
        if (replayed) require(syncId != null) { "Replayed events require their backlog sync ID" }
        if (!replayed) require(syncId == null) { "Live events cannot carry a backlog sync ID" }
        val body = EkoJson.decodeFromString<DurableEventBody>(entity.payloadJson)
        return eventBody(body, entity.contentHash, entity.seq, null, null, replayed, syncId)
    }

    fun fetch(record: FetchRecord, requestId: String): JsonObject {
        val active = record.active ?: return buildJsonObject {
            put("type", "fetch_missing")
            put("request_id", requestId)
            put("key", record.key)
            put("state_seq", record.stateSeq)
        }
        val body = EkoJson.decodeFromString<DurableEventBody>(active.payloadJson).copy(event = EventKind.POSTED)
        return eventBody(body, active.contentHash, null, record.stateSeq, requestId, replayed = false, syncId = null, forceReconciled = true)
    }

    fun ping(pingId: String, phoneTime: Long) = buildJsonObject {
        put("type", "ping")
        put("ping_id", pingId)
        put("phone_time", phoneTime)
    }

    fun error(code: String) = buildJsonObject {
        put("type", "error")
        put("code", code)
        put("fatal", true)
    }

    fun unpairAck(
        unpairId: String,
        initiatorId: String,
        peerId: String,
        status: String,
    ) = buildJsonObject {
        put("type", "unpair_ack")
        put("unpair_id", unpairId)
        put("initiator_id", initiatorId)
        put("peer_id", peerId)
        put("status", status)
    }

    private fun gap(gap: GapSpanEntity, syncId: String) = buildJsonObject {
        put("type", "backlog_gap")
        put("sync_id", syncId)
        put("from_seq", gap.fromSeq)
        put("to_seq", gap.toSeq)
        put("reason", gap.reason)
    }

    private fun activeChunk(
        syncId: String,
        index: Int,
        active: List<ActiveNotificationHeader>,
        final: Boolean,
    ) = buildJsonObject {
        put("type", "active_chunk")
        put("sync_id", syncId)
        put("index", index)
        put("final", final)
        put("active", buildJsonArray {
            active.forEach { notification ->
                add(buildJsonObject {
                    put("key", notification.key)
                    put("h", notification.contentHash)
                    put("state_seq", notification.lastSeq)
                })
            }
        })
    }

    private fun eventBody(
        body: DurableEventBody,
        contentHash: String?,
        seq: Long?,
        stateSeq: Long?,
        requestId: String?,
        replayed: Boolean,
        syncId: String?,
        forceReconciled: Boolean = false,
    ): JsonObject {
        return buildJsonObject {
            put("type", "event")
            seq?.let { put("seq", it) }
            stateSeq?.let { put("state_seq", it) }
            requestId?.let { put("request_id", it) }
            syncId?.let { put("sync_id", it) }
            put("ev", when (body.event) {
                EventKind.POSTED -> "posted"
                EventKind.UPDATED -> "updated"
                EventKind.REMOVED -> "removed"
                EventKind.CAPTURE_GAP -> "capture_gap"
            })
            when (body.event) {
                EventKind.POSTED, EventKind.UPDATED -> {
                    put("key", requireNotNull(body.key))
                    put("posted_at", requireNotNull(body.postedAt))
                    put("user", requireNotNull(body.user))
                    put("h", requireNotNull(contentHash))
                    put("app", EkoJson.encodeToJsonElement(requireNotNull(body.app)))
                    put("n", EkoJson.encodeToJsonElement(requireNotNull(body.notification)))
                    put("dnd", EkoJson.encodeToJsonElement(requireNotNull(body.dnd)))
                    put("truncated_fields", JsonArray(body.truncatedFields.map(::JsonPrimitive)))
                }
                EventKind.REMOVED -> {
                    put("key", requireNotNull(body.key))
                    put("posted_at", requireNotNull(body.postedAt))
                    put("user", requireNotNull(body.user))
                    put("h", JsonNull)
                    put("app", EkoJson.encodeToJsonElement(requireNotNull(body.app)))
                    put("dnd", EkoJson.encodeToJsonElement(requireNotNull(body.dnd)))
                    put("truncated_fields", JsonArray(body.truncatedFields.map(::JsonPrimitive)))
                    put("remove_reason", EkoJson.encodeToJsonElement(requireNotNull(body.removeReason)))
                }
                EventKind.CAPTURE_GAP -> {
                    put("h", JsonNull)
                    val gap = requireNotNull(body.captureGap)
                    put("confidence", gap.confidence)
                    put("interval", buildJsonObject {
                        put("start_at", gap.startAt?.let(::JsonPrimitive) ?: JsonNull)
                        put("end_at", gap.endAt?.let(::JsonPrimitive) ?: JsonNull)
                    })
                    put("evidence", gap.evidence)
                    gap.details?.let { put("details", it.take(2_048)) }
                }
            }
            put("flags", buildJsonObject {
                put("replayed", replayed)
                put("reconciled", forceReconciled || body.reconciled)
            })
        }
    }

    private fun strings(values: List<String>) = JsonArray(values.map(::JsonPrimitive))

    private fun boundedActiveChunks(
        syncId: String,
        active: List<ActiveNotificationHeader>,
    ): List<List<ActiveNotificationHeader>> {
        if (active.isEmpty()) return listOf(emptyList())
        val result = mutableListOf<List<ActiveNotificationHeader>>()
        var current = mutableListOf<ActiveNotificationHeader>()
        active.forEach { entry ->
            val candidate = current + entry
            val encodedBytes = activeChunk(syncId, result.size, candidate, final = false)
                .toString().encodeToByteArray().size + 1
            if (current.isNotEmpty() && (candidate.size > MAX_ACTIVE_ITEMS || encodedBytes > MAX_FRAME_LENGTH)) {
                result += current
                current = mutableListOf(entry)
            } else {
                check(encodedBytes <= MAX_FRAME_LENGTH) { "One active entry exceeds the frame limit" }
                current += entry
            }
        }
        if (current.isNotEmpty()) result += current
        return result
    }

    private const val MAX_ACTIVE_ITEMS = 4_096
}

internal fun JsonObject.strictString(name: String): String {
    val primitive = this[name] as? JsonPrimitive ?: throw ProtocolException("Missing string '$name'")
    if (!primitive.isString) throw ProtocolException("Field '$name' must be a string")
    return primitive.content
}

internal fun JsonObject.optionalString(name: String): String? {
    val element = this[name] ?: return null
    if (element is JsonNull) return null
    val primitive = element as? JsonPrimitive ?: throw ProtocolException("Field '$name' must be a string")
    if (!primitive.isString) throw ProtocolException("Field '$name' must be a string")
    return primitive.content
}

internal fun JsonObject.strictLong(name: String): Long {
    val primitive = this[name] as? JsonPrimitive ?: throw ProtocolException("Missing integer '$name'")
    if (primitive.isString) throw ProtocolException("Field '$name' must be an integer")
    if (!UINT_LEXICAL.matches(primitive.content)) {
        throw ProtocolException("Field '$name' must use canonical unsigned integer notation")
    }
    val value = primitive.longOrNull ?: throw ProtocolException("Field '$name' is outside the integer range")
    if (value > MAX_UINT53) throw ProtocolException("Field '$name' exceeds the v1 integer range")
    return value
}

internal fun JsonObject.strictBoolean(name: String): Boolean {
    val primitive = this[name] as? JsonPrimitive ?: throw ProtocolException("Missing boolean '$name'")
    if (primitive.isString || primitive.content != "true" && primitive.content != "false") {
        throw ProtocolException("Field '$name' must be a boolean")
    }
    return primitive.content == "true"
}

internal fun JsonObject.stringList(name: String): List<String> {
    val array = this[name] as? JsonArray ?: throw ProtocolException("Field '$name' must be an array")
    return array.mapIndexed { index, element ->
        val primitive = element as? JsonPrimitive
            ?: throw ProtocolException("Field '$name[$index]' must be a string")
        if (!primitive.isString) throw ProtocolException("Field '$name[$index]' must be a string")
        primitive.content
    }
}

private val UINT_LEXICAL = Regex("^(?:0|[1-9][0-9]*)$")
private const val MAX_UINT53 = 9_007_199_254_740_991L
