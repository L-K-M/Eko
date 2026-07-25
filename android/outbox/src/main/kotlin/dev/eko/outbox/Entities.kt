package dev.eko.outbox

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index

@Entity(tableName = "metadata")
data class MetadataEntity(
    @androidx.room.PrimaryKey val id: Int = 1,
    @ColumnInfo(name = "outbox_gen") val outboxGeneration: String,
    @ColumnInfo(name = "last_assigned_seq") val lastAssignedSeq: Long,
)

@Entity(
    tableName = "outbox",
    indices = [Index("notification_key"), Index("created_wall")],
)
data class OutboxEventEntity(
    @androidx.room.PrimaryKey val seq: Long,
    @ColumnInfo(name = "notification_key") val notificationKey: String,
    @ColumnInfo(name = "event_type") val eventType: String,
    @ColumnInfo(name = "payload_json") val payloadJson: String,
    @ColumnInfo(name = "content_hash") val contentHash: String?,
    @ColumnInfo(name = "created_wall") val createdWall: Long,
    @ColumnInfo(name = "created_elapsed") val createdElapsed: Long,
    @ColumnInfo(name = "created_boot") val createdBoot: String,
)

@Entity(tableName = "pairing_cursor")
data class PairingCursorEntity(
    @androidx.room.PrimaryKey @ColumnInfo(name = "pairing_id") val pairingId: String,
    @ColumnInfo(name = "acked_seq") val ackedSeq: Long = 0,
    @ColumnInfo(name = "serve_from_seq") val serveFromSeq: Long,
    @ColumnInfo(name = "retention_age_ms") val retentionAgeMs: Long = DEFAULT_RETENTION_AGE_MS,
    @ColumnInfo(name = "retention_count") val retentionCount: Int = DEFAULT_RETENTION_COUNT,
)

@Entity(
    tableName = "gap_span",
    primaryKeys = ["pairing_id", "outbox_gen", "from_seq", "to_seq"],
    indices = [Index(value = ["pairing_id", "outbox_gen", "from_seq"])],
)
data class GapSpanEntity(
    @ColumnInfo(name = "pairing_id") val pairingId: String,
    @ColumnInfo(name = "outbox_gen") val outboxGeneration: String,
    @ColumnInfo(name = "from_seq") val fromSeq: Long,
    @ColumnInfo(name = "to_seq") val toSeq: Long,
    val reason: String,
    @ColumnInfo(name = "start_wall") val startWall: Long? = null,
    @ColumnInfo(name = "end_wall") val endWall: Long? = null,
    val confidence: String = "definitive",
)

@Entity(
    tableName = "active_notification",
    indices = [Index(value = ["package_name", "user_id"])],
)
data class ActiveNotificationEntity(
    @androidx.room.PrimaryKey val key: String,
    @ColumnInfo(name = "user_id") val userId: Int,
    @ColumnInfo(name = "package_name") val packageName: String,
    @ColumnInfo(name = "payload_json") val payloadJson: String,
    @ColumnInfo(name = "content_hash") val contentHash: String,
    @ColumnInfo(name = "last_seq") val lastSeq: Long,
    val ongoing: Boolean,
)

@Entity(tableName = "app_rule", primaryKeys = ["package_name", "user_id"])
data class AppRuleEntity(
    @ColumnInfo(name = "package_name") val packageName: String,
    @ColumnInfo(name = "user_id") val userId: Int,
    val enabled: Boolean = true,
    @ColumnInfo(name = "include_ongoing") val includeOngoing: Boolean = false,
    @ColumnInfo(name = "otp_hint") val otpHint: Boolean = false,
)

@Entity(tableName = "seen_app", primaryKeys = ["package_name", "user_id"])
data class SeenAppEntity(
    @ColumnInfo(name = "package_name") val packageName: String,
    @ColumnInfo(name = "user_id") val userId: Int,
    val label: String,
    @ColumnInfo(name = "last_seen_wall") val lastSeenWall: Long,
)

data class AppWithRule(
    @ColumnInfo(name = "package_name") val packageName: String,
    @ColumnInfo(name = "user_id") val userId: Int,
    val label: String,
    @ColumnInfo(name = "last_seen_wall") val lastSeenWall: Long,
    val enabled: Boolean,
    @ColumnInfo(name = "include_ongoing") val includeOngoing: Boolean,
    @ColumnInfo(name = "otp_hint") val otpHint: Boolean,
)

data class GapBounds(
    @ColumnInfo(name = "min_from") val minFrom: Long?,
    @ColumnInfo(name = "max_to") val maxTo: Long?,
    @ColumnInfo(name = "min_wall") val minWall: Long?,
    @ColumnInfo(name = "max_wall") val maxWall: Long?,
)

const val DEFAULT_RETENTION_AGE_MS = 48L * 60 * 60 * 1_000
const val DEFAULT_RETENTION_COUNT = 2_000
