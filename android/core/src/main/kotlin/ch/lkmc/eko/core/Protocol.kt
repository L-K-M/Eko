package dev.eko.core

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.Transient
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

const val PROTOCOL_VERSION = 1
const val MAX_FRAME_LENGTH = 1_048_576
const val JSON_FRAME_TYPE = 0x01
const val BINARY_FRAME_TYPE = 0x02

val EkoJson = Json {
    encodeDefaults = true
    explicitNulls = true
    ignoreUnknownKeys = true
    isLenient = false
}

class ProtocolException(message: String, cause: Throwable? = null) : Exception(message, cause)

@Serializable
data class AppDescriptor(
    @SerialName("pkg") val packageName: String,
    val label: String,
    val category: String? = null,
)

@Serializable
data class MessageContent(
    val sender: String? = null,
    val text: String,
    @SerialName("ts") val timestamp: Long?,
)

@Serializable
data class NotificationContent(
    val title: String? = null,
    val text: String? = null,
    @SerialName("big_text") val bigText: String? = null,
    @SerialName("sub_text") val subText: String? = null,
    @SerialName("info_text") val infoText: String? = null,
    @SerialName("summary_text") val summaryText: String? = null,
    @SerialName("text_lines") val textLines: List<String>? = null,
    val messages: List<MessageContent>? = null,
    @SerialName("is_clearable") val isClearable: Boolean,
    @SerialName("is_group_summary") val isGroupSummary: Boolean,
    @SerialName("group_key") val groupKey: String? = null,
    @Transient val truncatedFields: List<String> = emptyList(),
)

@Serializable
data class DndDescriptor(
    val filter: String,
    val suppressed: Boolean,
)

@Serializable
enum class EventKind {
    @SerialName("posted") POSTED,
    @SerialName("updated") UPDATED,
    @SerialName("removed") REMOVED,
    @SerialName("capture_gap") CAPTURE_GAP,
}

@Serializable
data class CaptureGap(
    val confidence: String = "suspected",
    @SerialName("start_at") val startAt: Long? = null,
    @SerialName("end_at") val endAt: Long? = null,
    val evidence: String,
    val details: String? = null,
)

@Serializable
data class RemoveReason(
    val code: Int,
    val reconciled: Boolean,
)

@Serializable
data class DurableEventBody(
    @SerialName("_payload_version") val payloadVersion: Int = 1,
    @SerialName("ev") val event: EventKind,
    val key: String? = null,
    @SerialName("posted_at") val postedAt: Long? = null,
    val user: Int? = null,
    val app: AppDescriptor? = null,
    @SerialName("n") val notification: NotificationContent? = null,
    val dnd: DndDescriptor? = null,
    @SerialName("truncated_fields") val truncatedFields: List<String> = emptyList(),
    @SerialName("remove_reason") val removeReason: RemoveReason? = null,
    val reconciled: Boolean = false,
    @SerialName("capture_gap") val captureGap: CaptureGap? = null,
)

@Serializable
data class RawNotification(
    val title: String? = null,
    val text: String? = null,
    val bigText: String? = null,
    val subText: String? = null,
    val infoText: String? = null,
    val summaryText: String? = null,
    val textLines: List<String>? = null,
    val messages: List<MessageContent>? = null,
    val isClearable: Boolean,
    val isGroupSummary: Boolean,
    val groupKey: String? = null,
)

@Serializable
data class ProtocolEnvelope(val type: String)

fun JsonObject.requiredString(name: String): String {
    val primitive = this[name] as? JsonPrimitive
        ?: throw ProtocolException("Missing or invalid string field '$name'")
    if (!primitive.isString) throw ProtocolException("Field '$name' must be a string")
    return primitive.content
}
