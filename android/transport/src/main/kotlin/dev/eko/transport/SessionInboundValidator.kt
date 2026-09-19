package dev.eko.transport

import dev.eko.core.NotificationSanitizer
import dev.eko.core.ProtocolException
import kotlinx.serialization.json.JsonObject

internal sealed interface InboundControl {
    data class Ack(val seq: Long) : InboundControl
    data class Pong(val pingId: String, val phoneTime: Long, val macTime: Long) : InboundControl
    data class Dismiss(val key: String) : InboundControl
    data class Fetch(val requestId: String, val keys: List<String>) : InboundControl
    data class Unpair(val unpairId: String, val initiatorId: String, val peerId: String) : InboundControl
    data class ErrorFrame(val code: String, val fatal: Boolean) : InboundControl
    data object Ignored : InboundControl
}

internal enum class SessionState {
    /** Handshake incomplete: no session control frame is valid yet. */
    AWAIT_HELLO,
    /** Established normal session. */
    ESTABLISHED,
    /** Tombstoned peer: only the restricted unpair exchange remains. */
    RESTRICTED_UNPAIR,
}

internal class SessionInboundValidator(
    private val capabilities: Set<String>,
    private val peerDeviceId: String,
    private val localDeviceId: String,
    private val state: SessionState = SessionState.ESTABLISHED,
) {
    fun validate(message: JsonObject): InboundControl {
        val type = message.strictString("type")
        val validInState = when (state) {
            SessionState.AWAIT_HELLO -> type == "hello"
            SessionState.ESTABLISHED -> true
            SessionState.RESTRICTED_UNPAIR -> type in RESTRICTED_UNPAIR_TYPES
        }
        if (!validInState) {
            throw ProtocolException("Frame '$type' is not valid in the ${state.name.lowercase()} state")
        }
        return validateControl(type, message)
    }

    private fun validateControl(type: String, message: JsonObject): InboundControl = when (type) {
        "ack" -> InboundControl.Ack(message.strictLong("seq"))
        "pong" -> InboundControl.Pong(
            pingId = message.strictString("ping_id").requireUuidV4("ping_id"),
            phoneTime = message.strictLong("phone_time"),
            macTime = message.strictLong("mac_time"),
        )
        "dismiss" -> {
            requireCapability("dismiss", type)
            val key = message.strictString("key")
            if (!NotificationSanitizer.isValidOpaqueIdentifier(key, NotificationSanitizer.KEY_BYTES)) {
                throw ProtocolException("Dismiss key is invalid or oversized")
            }
            InboundControl.Dismiss(key)
        }
        "fetch" -> {
            requireCapability("notif", type)
            val requestId = message.strictString("request_id").requireUuidV4("request_id")
            val keys = message.stringList("keys")
            if (keys.isEmpty() || keys.size > 128 || keys.distinct().size != keys.size) {
                throw ProtocolException("Fetch keys must contain 1 through 128 unique values")
            }
            if (keys.any { !NotificationSanitizer.isValidOpaqueIdentifier(it, NotificationSanitizer.KEY_BYTES) }) {
                throw ProtocolException("Fetch contains an invalid or oversized key")
            }
            InboundControl.Fetch(requestId, keys)
        }
        "unpair" -> {
            val unpairId = message.strictString("unpair_id").requireUuidV4("unpair_id")
            val initiatorId = message.strictString("initiator_id")
            val peerId = message.strictString("peer_id")
            if (initiatorId != peerDeviceId || peerId != localDeviceId ||
                message.strictString("reason") !in setOf("user_request", "identity_replaced")
            ) throw ProtocolException("Unpair identities do not match the authenticated connection")
            InboundControl.Unpair(unpairId, initiatorId, peerId)
        }
        // The code is peer-controlled text that flows into UI state and the
        // diagnostics log ring; bound it so a peer cannot stuff up-to-frame-size
        // strings into either.
        "error" -> InboundControl.ErrorFrame(message.strictString("code").take(MAX_ERROR_CODE_CHARS), message.strictBoolean("fatal"))
        in OTHER_STATE_TYPES -> throw ProtocolException("Frame '$type' is not valid in the current session state")
        else -> {
            if ("ext_types" !in capabilities) {
                throw ProtocolException("Unknown message type without negotiated extension capability")
            }
            InboundControl.Ignored
        }
    }

    private fun requireCapability(capability: String, type: String) {
        if (capability !in capabilities) {
            throw ProtocolException("Frame '$type' requires the unnegotiated '$capability' capability")
        }
    }

    private companion object {
        const val MAX_ERROR_CODE_CHARS = 256
        val RESTRICTED_UNPAIR_TYPES = setOf("unpair", "unpair_ack", "error")
        val OTHER_STATE_TYPES = setOf(
            "hello", "welcome", "pair_request", "pair_commit", "pair_reveal", "pair_result",
            "backlog_start", "backlog_gap", "active_chunk", "backlog_end", "event",
            "fetch_missing", "ping", "unpair_ack",
        )
    }
}

internal fun String.requireUuidV4(field: String): String {
    if (!Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$").matches(this)) {
        throw ProtocolException("Field '$field' must be a canonical UUIDv4")
    }
    return this
}
