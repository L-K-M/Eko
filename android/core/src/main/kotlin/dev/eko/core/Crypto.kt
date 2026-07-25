package dev.eko.core

import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.SSLEngine
import javax.net.ssl.X509ExtendedTrustManager
import java.net.Socket
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

fun sha256(bytes: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(bytes)

fun ByteArray.hexLower(): String = joinToString("") { "%02x".format(it.toInt() and 0xff) }

fun String.hexBytes(): ByteArray {
    if (length % 2 != 0 || any { it.digitToIntOrNull(16) == null }) {
        throw IllegalArgumentException("Expected an even-length hexadecimal string")
    }
    return ByteArray(length / 2) { index -> substring(index * 2, index * 2 + 2).toInt(16).toByte() }
}

fun certificateFingerprint(certificateDer: ByteArray): String = sha256(certificateDer).hexLower()

object CanonicalJson {
    fun encode(element: JsonElement): ByteArray = render(element).toByteArray(Charsets.UTF_8)

    fun hash(element: JsonElement): String = sha256(encode(element)).hexLower()

    private fun render(element: JsonElement): String = when (element) {
        is JsonObject -> element.entries.sortedBy { it.key }.joinToString(",", "{", "}") {
            "${JsonPrimitive(it.key)}:${render(it.value)}"
        }
        is JsonArray -> element.joinToString(",", "[", "]") { render(it) }
        JsonNull -> "null"
        is JsonPrimitive -> element.toString()
    }
}

object Sas {
    private const val COMMIT_DOMAIN = "eko-pair-commit-v1"
    private const val SAS_DOMAIN = "eko-pair-sas-v1"

    fun newAttemptId(random: SecureRandom = SecureRandom()): ByteArray = randomBytes(16, random)

    fun newNonce(random: SecureRandom = SecureRandom()): ByteArray = randomBytes(32, random)

    fun commitment(attemptId: ByteArray, certificateDer: ByteArray, nonce: ByteArray): ByteArray {
        require(attemptId.size == 16) { "Pair attempt IDs are exactly 16 bytes in v1" }
        require(nonce.size == 32) { "Pairing nonces are exactly 32 bytes in v1" }
        return sha256(concat(COMMIT_DOMAIN.toByteArray(), lp(attemptId), lp(certificateDer), nonce))
    }

    fun verifyCommitment(
        expected: ByteArray,
        attemptId: ByteArray,
        certificateDer: ByteArray,
        nonce: ByteArray,
    ): Boolean = MessageDigest.isEqual(expected, commitment(attemptId, certificateDer, nonce))

    fun verificationCode(
        attemptId: ByteArray,
        certificateA: ByteArray,
        nonceA: ByteArray,
        certificateB: ByteArray,
        nonceB: ByteArray,
    ): String {
        require(attemptId.size == 16)
        require(nonceA.size == 32 && nonceB.size == 32)
        return transcriptHash(attemptId, certificateA, nonceA, certificateB, nonceB).take(8).uppercase()
    }

    fun transcriptHash(
        attemptId: ByteArray,
        certificateA: ByteArray,
        nonceA: ByteArray,
        certificateB: ByteArray,
        nonceB: ByteArray,
    ): String {
        require(attemptId.size == 16) { "Pair attempt IDs are exactly 16 bytes in v1" }
        require(nonceA.size == 32 && nonceB.size == 32) { "Pairing nonces are exactly 32 bytes in v1" }
        require(!certificateA.contentEquals(certificateB)) { "Pairing certificates must differ" }
        val owners = listOf(certificateA to nonceA, certificateB to nonceB)
            .sortedWith { left, right -> compareUnsigned(left.first, right.first) }
        val tuples = owners.map { (certificate, nonce) -> concat(lp(certificate), lp(nonce)) }
        return sha256(
            concat(
                SAS_DOMAIN.toByteArray(),
                lp(attemptId),
                lp(tuples[0]),
                lp(tuples[1]),
            ),
        ).hexLower()
    }

    private fun lp(bytes: ByteArray): ByteArray = ByteBuffer.allocate(4 + bytes.size)
        .order(ByteOrder.BIG_ENDIAN)
        .putInt(bytes.size)
        .put(bytes)
        .array()

    private fun concat(vararg fields: ByteArray): ByteArray = ByteArrayOutputStream().use { output ->
        fields.forEach(output::write)
        output.toByteArray()
    }

    private fun randomBytes(size: Int, random: SecureRandom) = ByteArray(size).also(random::nextBytes)

    private fun compareUnsigned(left: ByteArray, right: ByteArray): Int {
        for (index in 0 until minOf(left.size, right.size)) {
            val comparison = (left[index].toInt() and 0xff).compareTo(right[index].toInt() and 0xff)
            if (comparison != 0) return comparison
        }
        return left.size.compareTo(right.size)
    }
}

class ExactDerTrustManager(
    acceptedCertificates: Collection<ByteArray>,
    private val expectedPairingFingerprint: String? = null,
    private val allowUnknownDuringPairing: Boolean = false,
) : X509ExtendedTrustManager() {
    private val accepted = acceptedCertificates.map(ByteArray::copyOf)

    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) = check(chain)
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, socket: Socket?) = check(chain)
    override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = check(chain)
    override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?, engine: SSLEngine?) = check(chain)
    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    private fun check(chain: Array<out X509Certificate>?) {
        val leaf = chain?.firstOrNull()?.encoded ?: throw CertificateException("Peer supplied no leaf certificate")
        if (accepted.any { MessageDigest.isEqual(it, leaf) }) return
        val fingerprint = certificateFingerprint(leaf)
        if (expectedPairingFingerprint?.lowercase() == fingerprint) return
        if (allowUnknownDuringPairing && expectedPairingFingerprint == null) return
        throw CertificateException("Peer certificate does not match the exact DER pin")
    }
}
