package dev.eko.transport

import android.content.Context
import android.util.Base64
import dev.eko.core.Frame
import dev.eko.core.FrameCodec
import dev.eko.core.JSON_FRAME_TYPE
import dev.eko.core.PairingAction
import dev.eko.core.PairingMachine
import dev.eko.core.ProtocolException
import dev.eko.core.Sas
import dev.eko.core.certificateFingerprint
import dev.eko.core.hexBytes
import dev.eko.core.hexLower
import dev.eko.outbox.EventStoreProvider
import dev.eko.pairing.AndroidIdentity
import dev.eko.pairing.ConfirmedPeer
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.ManagedProfileGuard
import dev.eko.pairing.PairingCoordinator
import dev.eko.pairing.PeerEndpoint
import dev.eko.pairing.PendingPairing
import java.io.Closeable
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean
import android.os.SystemClock
import android.provider.Settings
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

data class PairingConnectionRequest(
    val endpoint: PeerEndpoint,
    val expectedFingerprint: String? = null,
    val oneTimeToken: String? = null,
    val resumeAttemptId: String? = null,
)

class PairingHandle internal constructor(
    val verificationCode: String,
    val attemptId: String,
    val peerName: String,
    val expiresAtElapsed: Long,
    private val localDeviceId: String,
    private val peerDeviceId: String,
    private val socket: Socket,
    private val transcriptHash: String,
    private val coordinator: PairingCoordinator,
    private val nowElapsed: () -> Long = SystemClock::elapsedRealtime,
) : Closeable {
    private val completed = AtomicBoolean(false)
    private val expiredState = AtomicBoolean(false)
    private val mutex = Mutex()

    val isExpired: Boolean
        get() = expiredState.get() || nowElapsed() >= expiresAtElapsed

    suspend fun expire() {
        if (completed.compareAndSet(false, true)) expireLocked()
    }

    private suspend fun expireLocked() {
        expiredState.set(true)
        runCatching { writeJson(socket, WireJson.error("pairing_expired")) }
        coordinator.reject(attemptId)
        close()
    }

    suspend fun confirm(accepted: Boolean): ConfirmedPeer? = mutex.withLock {
        if (isExpired) {
            if (completed.compareAndSet(false, true)) expireLocked()
            return@withLock null
        }
        check(completed.compareAndSet(false, true)) { "Pairing result was already sent" }
        try {
            if (!accepted) {
                writeJson(socket, pairResult("reject", localDeviceId, reason = "user_rejected"))
                coordinator.reject(attemptId)
                return@withLock null
            }
            coordinator.confirmLocal(attemptId)
            writeJson(socket, pairResult("accept", localDeviceId))

            val peerAccept = readExpected(socket, "pair_result")
            validatePeerResult(peerAccept)
            when (peerAccept.strictString("result")) {
                "reject" -> {
                    coordinator.reject(attemptId)
                    return@withLock null
                }
                "accept" -> coordinator.confirmPeer(attemptId)
                else -> throw ProtocolException("Mac must accept or reject before phone ready")
            }
            if (isExpired) {
                expireLocked()
                return@withLock null
            }

            val ready = coordinator.prepareReady(attemptId)
            writeJson(
                socket,
                pairResult(
                    result = "ready",
                    senderDeviceId = localDeviceId,
                    generation = ready.outboxGeneration,
                    cursor = ready.initialCursor,
                ),
            )
            val confirmed = readExpected(socket, "pair_result")
            validatePeerResult(confirmed)
            if (confirmed.strictString("result") != "confirmed" ||
                confirmed.strictString("outbox_gen") != ready.outboxGeneration ||
                confirmed.strictLong("initial_cursor") != ready.initialCursor
            ) throw ProtocolException("Mac did not exactly confirm phone ready state")
            val peer = coordinator.completeConfirmed(attemptId, ready.outboxGeneration, ready.initialCursor)

            val welcome = readExpected(socket, "welcome")
            if (welcome.strictString("device_id") != peerDeviceId ||
                welcome.strictString("outbox_gen") != ready.outboxGeneration ||
                welcome.strictLong("cursor") != ready.initialCursor ||
                welcome.strictLong("proto") != 1L ||
                "notif" !in welcome.stringList("caps")
            ) throw ProtocolException("Post-pair welcome does not match confirmed state")
            peer
        } finally {
            close()
        }
    }

    private fun pairResult(
        result: String,
        senderDeviceId: String,
        reason: String? = null,
        generation: String? = null,
        cursor: Long? = null,
    ) = buildJsonObject {
        put("type", "pair_result")
        put("attempt_id", attemptId)
        put("device_id", senderDeviceId)
        put("transcript_hash", transcriptHash)
        put("result", result)
        reason?.let { put("reason", it) }
        generation?.let { put("outbox_gen", it) }
        cursor?.let { put("initial_cursor", it) }
    }

    private fun validatePeerResult(message: JsonObject) {
        if (message.strictString("attempt_id") != attemptId ||
            message.strictString("device_id") != peerDeviceId ||
            message.strictString("transcript_hash") != transcriptHash
        ) throw ProtocolException("Pair result is not bound to this peer and transcript")
    }

    override fun close() {
        runCatching { socket.close() }
    }
}

class LanPairingClient(context: Context) {
    private val appContext = context.applicationContext
    private val identityStore = IdentityStore.get(appContext)
    private val coordinator = PairingCoordinator(appContext)

    suspend fun connect(request: PairingConnectionRequest): PairingHandle {
        ManagedProfileGuard.requirePersonalProfile(appContext)
        val identity = AndroidIdentity.getOrCreate(identityStore)
        val metadata = EventStoreProvider.repository(appContext).initialize()
        val existing = request.resumeAttemptId?.let { id ->
            identityStore.read().pendingPairings.firstOrNull { it.attemptId == id }
                ?: throw IllegalArgumentException("Pending pair attempt is unavailable")
        }
        if (existing != null) {
            require(existing.expiresAtWall > System.currentTimeMillis()) { "Pending pair attempt expired" }
            require(existing.endpoint == request.endpoint) { "Resume endpoint changed" }
            require(existing.outboxGeneration == metadata.outboxGeneration) { "Event generation changed during pairing" }
        }
        request.oneTimeToken?.let {
            require(QR_TOKEN.matches(it)) { "QR token must be 32-byte unpadded base64url" }
        }
        // A QR one-time token is a bearer credential whose only backup check is the
        // pinned fingerprint from the same QR payload. Sending it while
        // allow-unknown pairing TLS is active (no expected fingerprint) would
        // disclose the token to whoever terminates the connection.
        require(request.oneTimeToken == null || request.expectedFingerprint != null) {
            "A one-time token requires the pinned fingerprint from the same QR payload"
        }
        val method = existing?.method ?: if (request.oneTimeToken == null) "compare" else "qr"
        val attemptBytes = existing?.attemptId?.hexBytes() ?: Sas.newAttemptId()
        val attemptId = attemptBytes.hexLower()
        val localNonce = existing?.localNonceBase64?.let(::decodeBase64) ?: Sas.newNonce()
        val bootCount = Settings.Global.getInt(appContext.contentResolver, Settings.Global.BOOT_COUNT, -1)
        val expiresAt = existing?.expiresAtWall ?: System.currentTimeMillis() + PAIRING_WINDOW_MS
        val expiresAtElapsed = existing?.expiresAtElapsed ?: SystemClock.elapsedRealtime() + PAIRING_WINDOW_MS
        if (existing != null) require(existing.bootCount == bootCount && expiresAtElapsed > SystemClock.elapsedRealtime()) {
            "Pending pair attempt cannot resume across a reboot or after expiry"
        }
        var machine = PairingMachine(attemptId, expiresAtElapsed)
        val epoch = identityStore.nextConnectionEpoch()

        val networkMonitor = EligibleNetworkMonitor(appContext)
        val network = try {
            networkMonitor.awaitNetwork()
        } finally {
            networkMonitor.close()
        }
        val expected = existing?.peerDeviceId ?: request.expectedFingerprint
        val connection = withContext(Dispatchers.IO) {
            TlsConnector(identity).connectPairing(network, request.endpoint, expected)
        }
        val socket = connection.socket
        try {
            socket.soTimeout = ((expiresAt - System.currentTimeMillis()).coerceIn(1_000, Int.MAX_VALUE.toLong())).toInt()
            machine = machine.reduce(PairingAction.TlsReady, SystemClock.elapsedRealtime())
            writeJson(socket, buildJsonObject {
                put("type", "hello")
                put("mode", "pair")
                put("proto_min", 1)
                put("proto_max", 1)
                put("device_id", identity.deviceId)
                put("device_name", android.os.Build.MODEL.take(256).ifBlank { "Android" })
                put("os", "android")
                put("os_version", android.os.Build.VERSION.SDK_INT)
                put(
                    "caps",
                    kotlinx.serialization.json.JsonArray(
                        WireJson.capabilities.map { kotlinx.serialization.json.JsonPrimitive(it) },
                    ),
                )
                put("outbox_gen", metadata.outboxGeneration)
                put("conn_epoch", epoch)
                put("phone_time", System.currentTimeMillis())
                put("attempt_id", attemptId)
                request.oneTimeToken?.let { put("qr_token", it) }
            })

            val localCertificate = identity.certificate.encoded
            writeJson(socket, buildJsonObject {
                put("type", "pair_request")
                put("attempt_id", attemptId)
                put("role", "phone")
                put("method", method)
                put("device_id", identity.deviceId)
                put("device_name", android.os.Build.MODEL.take(256).ifBlank { "Android" })
                put("cert_der", encodeBase64(localCertificate))
            })
            val peerRequest = readExpected(socket, "pair_request")
            if (peerRequest.strictString("attempt_id") != attemptId ||
                peerRequest.strictString("role") != "mac" ||
                peerRequest.strictString("method") != method
            ) throw ProtocolException("Mac pair request does not match this attempt and method")
            val claimedBase64 = peerRequest.strictString("cert_der")
            val claimedPeerCertificate = decodeCanonicalBase64(claimedBase64)
            if (!claimedPeerCertificate.contentEquals(connection.peerCertificateDer)) {
                throw ProtocolException("Mac re-exchanged a certificate different from TLS")
            }
            val actualPeerId = certificateFingerprint(connection.peerCertificateDer)
            if (peerRequest.strictString("device_id") != actualPeerId ||
                expected?.lowercase()?.let { it != actualPeerId } == true
            ) throw ProtocolException("Mac pair identity does not match its TLS certificate")
            val peerName = peerRequest.strictString("device_name").take(256)

            val localCommitment = Sas.commitment(attemptBytes, localCertificate, localNonce)
            coordinator.persistPending(
                PendingPairing(
                    attemptId = attemptId,
                    peerDeviceId = actualPeerId,
                    peerName = peerName,
                    peerCertificateDerBase64 = claimedBase64,
                    endpoint = request.endpoint,
                    method = method,
                    outboxGeneration = metadata.outboxGeneration,
                    expiresAtWall = expiresAt,
                    expiresAtElapsed = expiresAtElapsed,
                    bootCount = bootCount,
                    localNonceBase64 = encodeBase64(localNonce),
                    localCommitHex = localCommitment.hexLower(),
                ),
            )
            writeJson(socket, buildJsonObject {
                put("type", "pair_commit")
                put("attempt_id", attemptId)
                put("device_id", identity.deviceId)
                put("commitment", localCommitment.hexLower())
            })
            machine = machine.reduce(PairingAction.LocalCommitSent, SystemClock.elapsedRealtime())
            val peerCommitFrame = readExpected(socket, "pair_commit")
            if (peerCommitFrame.strictString("attempt_id") != attemptId ||
                peerCommitFrame.strictString("device_id") != actualPeerId
            ) throw ProtocolException("Mac commitment identity or attempt mismatch")
            val peerCommitment = peerCommitFrame.strictString("commitment").requireLowerHex(64, "commitment").hexBytes()
            if (peerCommitment.size != 32) throw ProtocolException("Pair commitment must be SHA-256")
            machine = machine.reduce(PairingAction.PeerCommitReceived, SystemClock.elapsedRealtime())
            coordinator.persistPending(
                identityStore.read().pendingPairings.first { it.attemptId == attemptId }
                    .copy(peerCommitHex = peerCommitment.hexLower()),
            )

            writeJson(socket, buildJsonObject {
                put("type", "pair_reveal")
                put("attempt_id", attemptId)
                put("device_id", identity.deviceId)
                put("nonce", localNonce.hexLower())
            })
            val peerReveal = readExpected(socket, "pair_reveal")
            if (peerReveal.strictString("attempt_id") != attemptId ||
                peerReveal.strictString("device_id") != actualPeerId
            ) throw ProtocolException("Mac reveal identity or attempt mismatch")
            val peerNonce = peerReveal.strictString("nonce").requireLowerHex(64, "nonce").hexBytes()
            if (peerNonce.size != 32 || !Sas.verifyCommitment(peerCommitment, attemptBytes, claimedPeerCertificate, peerNonce)) {
                throw ProtocolException("Mac reveal does not match its commitment")
            }
            existing?.peerNonceBase64?.let { persisted ->
                if (!decodeBase64(persisted).contentEquals(peerNonce)) {
                    throw ProtocolException("Resumed Mac changed its committed nonce")
                }
            }
            val transcriptHash = Sas.transcriptHash(
                attemptBytes,
                localCertificate,
                localNonce,
                claimedPeerCertificate,
                peerNonce,
            )
            val code = transcriptHash.take(8).uppercase()
            machine = machine.reduce(PairingAction.RevealVerified(code), SystemClock.elapsedRealtime())
            coordinator.persistPending(
                PendingPairing(
                    attemptId = attemptId,
                    peerDeviceId = actualPeerId,
                    peerName = peerName,
                    peerCertificateDerBase64 = claimedBase64,
                    endpoint = request.endpoint,
                    transcriptHash = transcriptHash,
                    method = method,
                    outboxGeneration = metadata.outboxGeneration,
                    expiresAtWall = expiresAt,
                    expiresAtElapsed = expiresAtElapsed,
                    bootCount = bootCount,
                    localNonceBase64 = encodeBase64(localNonce),
                    peerNonceBase64 = encodeBase64(peerNonce),
                    localCommitHex = localCommitment.hexLower(),
                    peerCommitHex = peerCommitment.hexLower(),
                    verificationCode = code,
                ),
            )
            return PairingHandle(
                code,
                attemptId,
                peerName,
                expiresAtElapsed,
                identity.deviceId,
                actualPeerId,
                socket,
                transcriptHash,
                coordinator,
            )
        } catch (error: Throwable) {
            runCatching { socket.close() }
            throw error
        }
    }

    private companion object {
        const val PAIRING_WINDOW_MS = 5 * 60_000L
        val QR_TOKEN = Regex("^[A-Za-z0-9_-]{43}$")
    }
}

private suspend fun readExpected(socket: Socket, type: String): JsonObject = withContext(Dispatchers.IO) {
    val frame = FrameCodec.readJson(socket.getInputStream())
    when (frame.strictString("type")) {
        type -> frame
        // Surface the Mac's stated reason (unauthorized, pairing_expired, …)
        // instead of a generic frame-type mismatch.
        "error" -> throw ProtocolException("The Mac refused pairing: ${frame.optionalString("code")?.takeIf(String::isNotBlank) ?: "unknown error"}")
        else -> throw ProtocolException("Expected $type pairing frame")
    }
}

private suspend fun writeJson(socket: Socket, message: JsonObject) = withContext(Dispatchers.IO) {
    FrameCodec.write(socket.getOutputStream(), Frame(JSON_FRAME_TYPE, message.toString().encodeToByteArray()))
}

private fun encodeBase64(bytes: ByteArray): String = Base64.encodeToString(bytes, Base64.NO_WRAP)

private fun decodeCanonicalBase64(value: String): ByteArray = decodeBase64(value).also { decoded ->
    if (encodeBase64(decoded) != value) throw ProtocolException("Certificate DER base64 is not canonical")
}

private fun decodeBase64(value: String): ByteArray = try {
    Base64.decode(value, Base64.NO_WRAP)
} catch (error: IllegalArgumentException) {
    throw ProtocolException("Pairing field is not valid base64", error)
}

private fun String.requireLowerHex(length: Int, field: String): String {
    if (this.length != length || !all { it in '0'..'9' || it in 'a'..'f' }) {
        throw ProtocolException("Pairing field '$field' must be $length lowercase hex characters")
    }
    return this
}
