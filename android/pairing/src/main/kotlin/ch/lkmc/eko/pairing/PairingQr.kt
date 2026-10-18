package dev.eko.pairing

import dev.eko.core.EkoJson
import dev.eko.core.ProtocolException
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.intOrNull

data class PairingQrPayload(
    val endpoint: PeerEndpoint,
    val certificateFingerprint: String,
    val token: String,
)

object PairingQr {
    private val fingerprintPattern = Regex("^[0-9a-fA-F]{64}$")

    fun parse(value: String): PairingQrPayload {
        require(value.encodeToByteArray().size <= 4_096) { "Pairing QR payload is oversized" }
        val objectValue = runCatching { EkoJson.parseToJsonElement(value) as? JsonObject }.getOrNull()
            ?: throw ProtocolException("Pairing QR must contain a JSON object")
        val host = objectValue.string("host")
        val port = objectValue.integer("port")
        val fingerprint = objectValue.stringOrNull("certFingerprint")
            ?: objectValue.stringOrNull("cert_fingerprint")
            ?: objectValue.string("certFingerprint")
        val token = objectValue.stringOrNull("oneTimeToken")
            ?: objectValue.stringOrNull("token")
            ?: objectValue.string("token")
        require(fingerprintPattern.matches(fingerprint)) { "Pairing fingerprint must be 64 hexadecimal characters" }
        require(Regex("^[A-Za-z0-9_-]{43}$").matches(token)) {
            "Pairing token must be 32-byte unpadded base64url"
        }
        return PairingQrPayload(PeerEndpoint(host, port), fingerprint.lowercase(), token)
    }

    private fun JsonObject.string(name: String): String = stringOrNull(name)
        ?: throw ProtocolException("Pairing QR is missing '$name'")

    private fun JsonObject.stringOrNull(name: String): String? {
        val value = this[name] ?: return null
        val primitive = value as? JsonPrimitive ?: throw ProtocolException("Pairing QR '$name' must be a string")
        if (!primitive.isString) throw ProtocolException("Pairing QR '$name' must be a string")
        return primitive.content
    }

    private fun JsonObject.integer(name: String): Int {
        val primitive = this[name] as? JsonPrimitive ?: throw ProtocolException("Pairing QR is missing '$name'")
        if (primitive.isString) throw ProtocolException("Pairing QR '$name' must be an integer")
        return primitive.intOrNull ?: throw ProtocolException("Pairing QR '$name' is outside the integer range")
    }
}
