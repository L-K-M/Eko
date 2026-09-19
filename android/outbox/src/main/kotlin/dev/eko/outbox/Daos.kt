package dev.eko.outbox

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import kotlinx.coroutines.flow.Flow

@Dao
interface MetadataDao {
    @Query("SELECT * FROM metadata WHERE id = 1")
    suspend fun get(): MetadataEntity?

    @Query("SELECT * FROM metadata WHERE id = 1")
    fun observe(): Flow<MetadataEntity?>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(entity: MetadataEntity): Long

    @Query("UPDATE metadata SET last_assigned_seq = :next WHERE id = 1 AND last_assigned_seq = :expected")
    suspend fun advance(expected: Long, next: Long): Int
}

@Dao
interface OutboxDao {
    @Insert
    suspend fun insert(entity: OutboxEventEntity)

    @Query("SELECT * FROM outbox WHERE seq BETWEEN :fromSeq AND :toSeq ORDER BY seq")
    suspend fun between(fromSeq: Long, toSeq: Long): List<OutboxEventEntity>

    @Query("SELECT seq FROM outbox WHERE seq BETWEEN :fromSeq AND :toSeq ORDER BY seq")
    suspend fun seqsBetween(fromSeq: Long, toSeq: Long): List<Long>

    @Query("SELECT * FROM outbox WHERE seq IN (:seqs) ORDER BY seq")
    suspend fun bySeqs(seqs: List<Long>): List<OutboxEventEntity>

    @Query("SELECT * FROM outbox WHERE seq >= :fromSeq ORDER BY seq")
    suspend fun from(fromSeq: Long): List<OutboxEventEntity>

    @Query("SELECT * FROM outbox WHERE seq > :afterSeq ORDER BY seq LIMIT :limit")
    suspend fun after(afterSeq: Long, limit: Int): List<OutboxEventEntity>

    @Query("SELECT COUNT(*) FROM outbox")
    fun observeCount(): Flow<Int>

    @Query(
        """
        DELETE FROM outbox
        WHERE NOT EXISTS (
            SELECT 1 FROM pairing_cursor p
            WHERE outbox.seq > p.acked_seq
              AND outbox.seq >= p.serve_from_seq
        )
        """,
    )
    suspend fun deleteUnneeded(): Int
}

@Dao
interface PairingCursorDao {
    @Query("SELECT * FROM pairing_cursor WHERE pairing_id = :pairingId")
    suspend fun get(pairingId: String): PairingCursorEntity?

    @Query("SELECT * FROM pairing_cursor ORDER BY pairing_id")
    suspend fun all(): List<PairingCursorEntity>

    @Query("SELECT * FROM pairing_cursor ORDER BY pairing_id")
    fun observeAll(): Flow<List<PairingCursorEntity>>

    @Insert(onConflict = OnConflictStrategy.IGNORE)
    suspend fun insert(entity: PairingCursorEntity): Long

    @Update
    suspend fun update(entity: PairingCursorEntity)

    @Query("DELETE FROM pairing_cursor WHERE pairing_id = :pairingId")
    suspend fun delete(pairingId: String)
}

@Dao
interface GapSpanDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(entity: GapSpanEntity)

    @Query(
        """
        SELECT * FROM gap_span
        WHERE pairing_id = :pairingId AND outbox_gen = :generation
          AND to_seq >= :fromSeq AND from_seq <= :toSeq
        ORDER BY from_seq
        """,
    )
    suspend fun overlapping(
        pairingId: String,
        generation: String,
        fromSeq: Long,
        toSeq: Long,
    ): List<GapSpanEntity>

    @Query(
        """
        SELECT MIN(from_seq) AS min_from, MAX(to_seq) AS max_to,
               MIN(start_wall) AS min_wall, MAX(end_wall) AS max_wall
        FROM gap_span
        WHERE pairing_id = :pairingId AND outbox_gen = :generation AND reason = :reason
          AND from_seq <= :toSeq + 1 AND to_seq >= :fromSeq - 1
        """,
    )
    suspend fun adjacentBounds(
        pairingId: String,
        generation: String,
        reason: String,
        fromSeq: Long,
        toSeq: Long,
    ): GapBounds

    @Query(
        """
        DELETE FROM gap_span
        WHERE pairing_id = :pairingId AND outbox_gen = :generation AND reason = :reason
          AND from_seq <= :toSeq + 1 AND to_seq >= :fromSeq - 1
        """,
    )
    suspend fun deleteAdjacent(
        pairingId: String,
        generation: String,
        reason: String,
        fromSeq: Long,
        toSeq: Long,
    )

    @Query("DELETE FROM gap_span WHERE pairing_id = :pairingId AND to_seq <= :throughSeq")
    suspend fun deleteDelivered(pairingId: String, throughSeq: Long)

    @Query("DELETE FROM gap_span WHERE pairing_id = :pairingId")
    suspend fun deleteForPairing(pairingId: String)
}

@Dao
interface ActiveNotificationDao {
    @Query("SELECT * FROM active_notification WHERE `key` = :key")
    suspend fun get(key: String): ActiveNotificationEntity?

    @Query("SELECT * FROM active_notification ORDER BY `key`")
    suspend fun all(): List<ActiveNotificationEntity>

    // Payload-free projection for backlog snapshots: the wire's active chunks
    // carry only key/hash/state_seq, and the full payload can be large.
    @Query("SELECT `key`, content_hash, last_seq FROM active_notification ORDER BY `key`")
    suspend fun headers(): List<ActiveNotificationHeader>

    @Query("SELECT * FROM active_notification WHERE package_name = :packageName AND user_id = :userId")
    suspend fun forApp(packageName: String, userId: Int): List<ActiveNotificationEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: ActiveNotificationEntity)

    @Query("DELETE FROM active_notification WHERE `key` = :key")
    suspend fun delete(key: String)
}

@Dao
interface AppRuleDao {
    @Query("SELECT * FROM app_rule WHERE package_name = :packageName AND user_id = :userId")
    suspend fun get(packageName: String, userId: Int): AppRuleEntity?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(entity: AppRuleEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertSeen(entity: SeenAppEntity)

    @Query(
        """
        SELECT s.package_name, s.user_id, s.label, s.last_seen_wall,
               COALESCE(r.enabled, 1) AS enabled,
               COALESCE(r.include_ongoing, 0) AS include_ongoing,
               COALESCE(r.otp_hint, 0) AS otp_hint
        FROM seen_app s
        LEFT JOIN app_rule r ON r.package_name = s.package_name AND r.user_id = s.user_id
        ORDER BY s.label COLLATE NOCASE, s.user_id
        """,
    )
    fun observeApps(): Flow<List<AppWithRule>>
}
