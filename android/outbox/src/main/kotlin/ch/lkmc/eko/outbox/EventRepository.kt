package dev.eko.outbox

import androidx.room.withTransaction
import dev.eko.core.AppDescriptor
import dev.eko.core.CanonicalJson
import dev.eko.core.CaptureGap
import dev.eko.core.DndDescriptor
import dev.eko.core.DurableEventBody
import dev.eko.core.EkoJson
import dev.eko.core.EventKind
import dev.eko.core.NotificationContent
import dev.eko.core.RemoveReason
import dev.eko.core.MAX_FRAME_LENGTH
import java.util.UUID
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.filterNotNull
import kotlinx.coroutines.flow.map
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.encodeToJsonElement

data class NotificationSnapshot(
    val key: String,
    val postedAt: Long,
    val userId: Int,
    val packageName: String,
    val appLabel: String,
    val category: String?,
    val content: NotificationContent,
    val dnd: DndDescriptor,
    val ongoing: Boolean,
)

sealed interface CaptureCommit {
    data class Committed(val seq: Long, val kind: EventKind) : CaptureCommit
    data object Filtered : CaptureCommit
    data object Unchanged : CaptureCommit
}

data class BacklogSnapshot(
    val generation: String,
    val highWater: Long,
    val replayFromSeq: Long,
    // Sequence positions only: the snapshot pins *which* rows must be replayed
    // without materializing their payloads (up to retentionCount rows of up to
    // the protocol's per-event byte cap — far too much to hold at once). Rows
    // are loaded page-by-page via replayPage when the frames are actually sent.
    val eventSeqs: List<Long>,
    val gaps: List<GapSpanEntity>,
    val active: List<ActiveNotificationHeader>,
)

data class FetchRecord(
    val key: String,
    val stateSeq: Long,
    val active: ActiveNotificationEntity?,
)

class CursorAheadOfHighWaterException(val cursor: Long, val highWater: Long) :
    IllegalStateException("Peer cursor $cursor exceeds durable high-water $highWater")

class InvalidAcknowledgementException(message: String) : IllegalArgumentException(message)

class EventRepository(
    private val database: EventDatabase,
    private val clock: BootAwareClock,
) {
    suspend fun initialize(generation: String = UUID.randomUUID().toString()): MetadataEntity =
        database.withTransaction { metadata(generation) }

    fun observeMetadata(): Flow<MetadataEntity> = database.metadata().observe().filterNotNull()

    fun observeOutboxCount(): Flow<Int> = database.outbox().observeCount()

    fun observePairings(): Flow<List<PairingCursorEntity>> = database.pairings().observeAll()

    suspend fun pairingRows(): List<PairingCursorEntity> = database.pairings().all()

    fun observeApps(): Flow<List<AppWithRule>> = database.appRules().observeApps()

    suspend fun commitNotification(
        snapshot: NotificationSnapshot,
        reconciled: Boolean = false,
    ): CaptureCommit = database.withTransaction {
        metadata()
        recordSeen(snapshot)
        if (!shouldForward(snapshot)) {
            val existing = database.active().get(snapshot.key)
            if (existing != null) return@withTransaction insertRemoval(existing, REMOVE_REASON_FILTERED, true)
            return@withTransaction CaptureCommit.Filtered
        }
        insertNotification(snapshot, reconciled, emitUnchanged = !reconciled)
    }

    suspend fun commitRemoval(
        key: String,
        reason: Int,
        reconciled: Boolean = false,
    ): CaptureCommit = database.withTransaction {
        metadata()
        val existing = database.active().get(key) ?: return@withTransaction CaptureCommit.Filtered
        insertRemoval(existing, reason, reconciled)
    }

    suspend fun commitCaptureGap(
        evidence: String,
        startWall: Long?,
        endWall: Long?,
    ): CaptureCommit.Committed = database.withTransaction {
        val key = "capture-gap:${UUID.randomUUID()}"
        val evidenceCode = evidence.substringBefore(':').takeIf {
            it == "listener_disconnected" || it == "process_exit" || it == "writer_overflow"
        } ?: "writer_overflow"
        val body = DurableEventBody(
            event = EventKind.CAPTURE_GAP,
            captureGap = CaptureGap(
                startAt = startWall,
                endAt = endWall,
                evidence = evidenceCode,
                details = evidence.takeIf { it != evidenceCode },
            ),
        )
        val seq = append(body, contentHash = null, storageKey = key)
        CaptureCommit.Committed(seq, EventKind.CAPTURE_GAP)
    }

    suspend fun reconcile(visible: List<NotificationSnapshot>): List<CaptureCommit.Committed> =
        database.withTransaction {
            metadata()
            val commits = mutableListOf<CaptureCommit.Committed>()
            val visibleByKey = visible.associateBy(NotificationSnapshot::key)
            val current = database.active().all().associateBy(ActiveNotificationEntity::key)

            current.values.filter { it.key !in visibleByKey }.forEach { existing ->
                commits += insertRemoval(existing, REMOVE_REASON_RECONCILED, reconciled = true)
            }
            visible.forEach { snapshot ->
                recordSeen(snapshot)
                val existing = current[snapshot.key]
                if (!shouldForward(snapshot)) {
                    if (existing != null) {
                        commits += insertRemoval(existing, REMOVE_REASON_FILTERED, reconciled = true)
                    }
                    return@forEach
                }
                when (val result = insertNotification(snapshot, reconciled = true, emitUnchanged = false)) {
                    is CaptureCommit.Committed -> commits += result
                    CaptureCommit.Filtered, CaptureCommit.Unchanged -> Unit
                }
            }
            commits
        }

    suspend fun ensurePairing(
        pairingId: String,
        retentionAgeMs: Long = DEFAULT_RETENTION_AGE_MS,
        retentionCount: Int = DEFAULT_RETENTION_COUNT,
    ): PairingCursorEntity = database.withTransaction {
        require(retentionAgeMs > 0 && retentionCount > 0)
        database.pairings().get(pairingId)?.let { return@withTransaction it }
        val highWater = metadata().lastAssignedSeq
        val pairing = PairingCursorEntity(
            pairingId = pairingId,
            ackedSeq = highWater,
            serveFromSeq = highWater + 1,
            retentionAgeMs = retentionAgeMs,
            retentionCount = retentionCount,
        )
        database.pairings().insert(pairing)
        prunePhysicalRows()
        pairing
    }

    suspend fun rehydratePairings(pairingIds: Collection<String>) = database.withTransaction {
        metadata()
        pairingIds.distinct().forEach { pairingId ->
            database.pairings().insert(
                PairingCursorEntity(pairingId = pairingId, ackedSeq = 0, serveFromSeq = 1),
            )
        }
    }

    suspend fun removePairing(pairingId: String) = database.withTransaction {
        database.pairings().delete(pairingId)
        database.gaps().deleteForPairing(pairingId)
        prunePhysicalRows()
    }

    suspend fun updateAppRule(rule: AppRuleEntity) = database.withTransaction {
        metadata()
        database.appRules().upsert(rule)
        if (!rule.enabled) {
            database.active().forApp(rule.packageName, rule.userId).forEach { existing ->
                insertRemoval(existing, REMOVE_REASON_FILTERED, reconciled = true)
            }
        } else if (!rule.includeOngoing) {
            database.active().forApp(rule.packageName, rule.userId).filter { it.ongoing }.forEach { existing ->
                insertRemoval(existing, REMOVE_REASON_FILTERED, reconciled = true)
            }
        }
    }

    suspend fun backlog(pairingId: String, peerCursor: Long): BacklogSnapshot = database.withTransaction {
        val metadata = metadata()
        if (peerCursor > metadata.lastAssignedSeq) {
            throw CursorAheadOfHighWaterException(peerCursor, metadata.lastAssignedSeq)
        }
        val pairing = database.pairings().get(pairingId)
            ?: throw IllegalStateException("No event-store cursor exists for pairing $pairingId")
        val effectiveFloor = maxOf(pairing.serveFromSeq, pairing.ackedSeq + 1)
        val unavailableFrom = peerCursor + 1
        val unavailableTo = effectiveFloor - 1
        val gaps = if (unavailableFrom <= unavailableTo) {
            completeGapCoverage(pairingId, metadata.outboxGeneration, unavailableFrom, unavailableTo)
        } else {
            emptyList()
        }
        val replayFrom = maxOf(peerCursor + 1, effectiveFloor)
        val replaySeqs = if (replayFrom <= metadata.lastAssignedSeq) {
            database.outbox().seqsBetween(replayFrom, metadata.lastAssignedSeq)
        } else {
            emptyList()
        }
        if (replaySeqs.withIndex().any { (index, seq) -> seq != replayFrom + index } ||
            replaySeqs.size.toLong() != (metadata.lastAssignedSeq - replayFrom + 1).coerceAtLeast(0)
        ) {
            throw IllegalStateException("Event-store snapshot contains an unauthorized sequence hole")
        }
        BacklogSnapshot(
            generation = metadata.outboxGeneration,
            highWater = metadata.lastAssignedSeq,
            replayFromSeq = replayFrom,
            eventSeqs = replaySeqs,
            gaps = gaps,
            active = database.active().headers(),
        )
    }

    /**
     * Loads one page of snapshot-pinned replay rows. Rows are immutable once
     * committed, but retention can delete them after the snapshot was taken; a
     * missing row makes this sync undeliverable, so the caller must drop the
     * session and resync against the peer's next cursor instead of skipping it.
     */
    suspend fun replayPage(seqs: List<Long>): List<OutboxEventEntity> {
        if (seqs.isEmpty()) return emptyList()
        val rows = database.outbox().bySeqs(seqs)
        if (rows.size != seqs.size || rows.withIndex().any { (index, row) -> row.seq != seqs[index] }) {
            throw IllegalStateException("Retention removed rows pinned by a backlog snapshot; resync required")
        }
        return rows
    }

    suspend fun fetch(keys: List<String>): List<FetchRecord> = database.withTransaction {
        require(keys.size <= MAX_FETCH_KEYS) { "Fetch is limited to $MAX_FETCH_KEYS keys" }
        val highWater = metadata().lastAssignedSeq
        keys.distinct().map { key ->
            val active = database.active().get(key)
            FetchRecord(key, active?.lastSeq ?: highWater, active)
        }
    }

    suspend fun eventsAfter(afterSeq: Long, limit: Int = 200): List<OutboxEventEntity> =
        database.outbox().after(afterSeq, limit.coerceIn(1, 500))

    suspend fun acknowledge(pairingId: String, seq: Long, highestAuthorized: Long) = database.withTransaction {
        val pairing = database.pairings().get(pairingId)
            ?: throw InvalidAcknowledgementException("ACK belongs to an unknown pairing")
        val highWater = metadata().lastAssignedSeq
        if (seq < pairing.ackedSeq) throw InvalidAcknowledgementException("ACK regressed")
        if (seq > highestAuthorized || seq > highWater) {
            throw InvalidAcknowledgementException("ACK exceeds this session's authorized sequence")
        }
        if (seq > pairing.ackedSeq) {
            database.pairings().update(pairing.copy(ackedSeq = seq))
            database.gaps().deleteDelivered(pairingId, seq)
            prunePhysicalRows()
        }
    }

    suspend fun applyRetention(pairingId: String) = database.withTransaction {
        val metadata = metadata()
        val pairing = database.pairings().get(pairingId) ?: return@withTransaction
        val effectiveFloor = maxOf(pairing.serveFromSeq, pairing.ackedSeq + 1)
        val pending = database.outbox().from(effectiveFloor)
        val now = clock.now()
        val expiredPrefix = pending.takeWhile { clock.isExpired(it, pairing.retentionAgeMs, now) }
        val ageFloor = expiredPrefix.lastOrNull()?.seq?.plus(1) ?: effectiveFloor
        val countFloor = if (pending.size > pairing.retentionCount) {
            pending[pending.size - pairing.retentionCount].seq
        } else {
            effectiveFloor
        }
        val newFloor = maxOf(ageFloor, countFloor)
        if (newFloor > effectiveFloor) {
            val skipped = pending.filter { it.seq < newFloor }
            insertMergedGap(
                pairingId,
                metadata.outboxGeneration,
                effectiveFloor,
                newFloor - 1,
                if (countFloor >= ageFloor) "retention_count" else "retention_age",
                skipped.firstOrNull()?.createdWall,
                skipped.lastOrNull()?.createdWall,
            )
            database.pairings().update(pairing.copy(serveFromSeq = newFloor))
        }
        prunePhysicalRows()
    }

    suspend fun setRetention(pairingId: String, ageMs: Long, count: Int) = database.withTransaction {
        require(ageMs > 0 && count > 0)
        val pairing = database.pairings().get(pairingId) ?: return@withTransaction
        database.pairings().update(pairing.copy(retentionAgeMs = ageMs, retentionCount = count))
    }.also { applyRetention(pairingId) }

    suspend fun pairingQueueDepth(pairingId: String): Int = database.withTransaction {
        val pairing = database.pairings().get(pairingId) ?: return@withTransaction 0
        database.outbox().from(maxOf(pairing.serveFromSeq, pairing.ackedSeq + 1)).size
    }

    suspend fun pruneUnneededRows(): Int = database.withTransaction { database.outbox().deleteUnneeded() }

    private suspend fun insertNotification(
        snapshot: NotificationSnapshot,
        reconciled: Boolean,
        emitUnchanged: Boolean,
    ): CaptureCommit {
        val existing = database.active().get(snapshot.key)
        val hash = CanonicalJson.hash(EkoJson.encodeToJsonElement(snapshot.content))
        if (existing?.contentHash == hash && !emitUnchanged) return CaptureCommit.Unchanged
        val kind = if (existing == null) EventKind.POSTED else EventKind.UPDATED
        val body = DurableEventBody(
            event = kind,
            key = snapshot.key,
            postedAt = snapshot.postedAt,
            user = snapshot.userId,
            app = AppDescriptor(snapshot.packageName, snapshot.appLabel, snapshot.category),
            notification = snapshot.content,
            dnd = snapshot.dnd,
            truncatedFields = snapshot.content.truncatedFields,
            reconciled = reconciled,
        )
        val encodedBody = EkoJson.encodeToString(body)
        if (encodedBody.encodeToByteArray().size > MAX_FRAME_LENGTH - EVENT_ENVELOPE_RESERVE_BYTES) {
            val now = clock.now().wall
            val gapBody = DurableEventBody(
                event = EventKind.CAPTURE_GAP,
                captureGap = CaptureGap(
                    startAt = now,
                    endAt = now,
                    evidence = "writer_overflow",
                    details = "notification_event_exceeded_frame_limit",
                ),
            )
            val gapKey = "capture-gap:${UUID.randomUUID()}"
            return CaptureCommit.Committed(append(gapBody, null, gapKey), EventKind.CAPTURE_GAP)
        }
        val seq = append(body, hash)
        database.active().upsert(
            ActiveNotificationEntity(
                key = snapshot.key,
                userId = snapshot.userId,
                packageName = snapshot.packageName,
                payloadJson = encodedBody,
                contentHash = hash,
                lastSeq = seq,
                ongoing = snapshot.ongoing,
            ),
        )
        return CaptureCommit.Committed(seq, kind)
    }

    private suspend fun insertRemoval(
        existing: ActiveNotificationEntity,
        reason: Int,
        reconciled: Boolean,
    ): CaptureCommit.Committed {
        val prior = EkoJson.decodeFromString<DurableEventBody>(existing.payloadJson)
        val body = DurableEventBody(
            event = EventKind.REMOVED,
            key = existing.key,
            postedAt = prior.postedAt,
            user = prior.user,
            app = prior.app,
            dnd = prior.dnd,
            truncatedFields = prior.truncatedFields,
            removeReason = RemoveReason(reason.coerceAtLeast(0), reconciled),
            reconciled = reconciled,
        )
        val seq = append(body, null)
        database.active().delete(existing.key)
        return CaptureCommit.Committed(seq, EventKind.REMOVED)
    }

    private suspend fun append(
        body: DurableEventBody,
        contentHash: String?,
        storageKey: String = requireNotNull(body.key),
    ): Long {
        val metadata = metadata()
        val next = Math.addExact(metadata.lastAssignedSeq, 1)
        check(database.metadata().advance(metadata.lastAssignedSeq, next) == 1) {
            "Metadata high-water changed inside a serialized write transaction"
        }
        val timestamp = clock.now()
        database.outbox().insert(
            OutboxEventEntity(
                seq = next,
                notificationKey = storageKey,
                eventType = body.event.name.lowercase(),
                payloadJson = EkoJson.encodeToString(body),
                contentHash = contentHash,
                createdWall = timestamp.wall,
                createdElapsed = timestamp.elapsed,
                createdBoot = timestamp.bootId,
            ),
        )
        return next
    }

    private suspend fun metadata(preferredGeneration: String = UUID.randomUUID().toString()): MetadataEntity {
        database.metadata().get()?.let { return it }
        val candidate = MetadataEntity(outboxGeneration = preferredGeneration, lastAssignedSeq = 0)
        database.metadata().insert(candidate)
        return database.metadata().get() ?: error("Unable to create event-store metadata")
    }

    private suspend fun recordSeen(snapshot: NotificationSnapshot) {
        database.appRules().upsertSeen(
            SeenAppEntity(snapshot.packageName, snapshot.userId, snapshot.appLabel, clock.now().wall),
        )
    }

    private suspend fun shouldForward(snapshot: NotificationSnapshot): Boolean {
        val rule = database.appRules().get(snapshot.packageName, snapshot.userId)
        return (rule?.enabled != false) && (!snapshot.ongoing || rule?.includeOngoing == true)
    }

    private suspend fun completeGapCoverage(
        pairingId: String,
        generation: String,
        fromSeq: Long,
        toSeq: Long,
    ): List<GapSpanEntity> {
        val existing = database.gaps().overlapping(pairingId, generation, fromSeq, toSeq)
        var cursor = fromSeq
        existing.forEach { gap ->
            if (cursor < gap.fromSeq) {
                insertMergedGap(pairingId, generation, cursor, gap.fromSeq - 1, "peer_cursor_regressed")
            }
            cursor = maxOf(cursor, gap.toSeq + 1)
        }
        if (cursor <= toSeq) {
            insertMergedGap(pairingId, generation, cursor, toSeq, "peer_cursor_regressed")
        }
        return database.gaps().overlapping(pairingId, generation, fromSeq, toSeq).map { gap ->
            gap.copy(fromSeq = maxOf(gap.fromSeq, fromSeq), toSeq = minOf(gap.toSeq, toSeq))
        }
    }

    private suspend fun insertMergedGap(
        pairingId: String,
        generation: String,
        fromSeq: Long,
        toSeq: Long,
        reason: String,
        startWall: Long? = null,
        endWall: Long? = null,
    ) {
        if (fromSeq > toSeq) return
        val bounds = database.gaps().adjacentBounds(pairingId, generation, reason, fromSeq, toSeq)
        database.gaps().deleteAdjacent(pairingId, generation, reason, fromSeq, toSeq)
        database.gaps().insert(
            GapSpanEntity(
                pairingId = pairingId,
                outboxGeneration = generation,
                fromSeq = minOf(fromSeq, bounds.minFrom ?: fromSeq),
                toSeq = maxOf(toSeq, bounds.maxTo ?: toSeq),
                reason = reason,
                startWall = listOfNotNull(startWall, bounds.minWall).minOrNull(),
                endWall = listOfNotNull(endWall, bounds.maxWall).maxOrNull(),
            ),
        )
    }

    private suspend fun prunePhysicalRows() {
        database.outbox().deleteUnneeded()
    }

    companion object {
        const val REMOVE_REASON_RECONCILED = -1
        const val REMOVE_REASON_FILTERED = -2
        const val MAX_FETCH_KEYS = 128
        const val EVENT_ENVELOPE_RESERVE_BYTES = 8_192
    }
}
