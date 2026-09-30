package dev.eko.pairing

import android.content.Context
import dev.eko.outbox.EventStoreProvider

class PairingCoordinator(context: Context) {
    private val appContext = context.applicationContext
    private val identityStore = IdentityStore.get(appContext)

    suspend fun persistPending(pending: PendingPairing) {
        val bootCount = android.provider.Settings.Global.getInt(
            appContext.contentResolver,
            android.provider.Settings.Global.BOOT_COUNT,
            -1,
        )
        require(pending.bootCount == bootCount && pending.expiresAtElapsed > android.os.SystemClock.elapsedRealtime()) {
            "Pairing attempt has expired"
        }
        identityStore.savePending(pending)
    }

    suspend fun confirmLocal(attemptId: String) {
        identityStore.markLocalConfirmed(attemptId)
    }

    suspend fun confirmPeer(attemptId: String) {
        identityStore.markPeerConfirmed(attemptId)
    }

    suspend fun prepareReady(attemptId: String): PairingReady {
        val pending = identityStore.read().pendingPairings.firstOrNull { it.attemptId == attemptId }
            ?: error("Pending pair attempt is unavailable")
        check(pending.localConfirmed && pending.peerConfirmed) { "Both pairing accepts are required" }
        val transcript = requireNotNull(pending.transcriptHash) { "Pairing transcript is incomplete" }
        val repository = EventStoreProvider.repository(appContext)
        val metadata = repository.initialize()
        check(metadata.outboxGeneration == pending.outboxGeneration) { "Event generation changed during pairing" }
        val cursor = repository.ensurePairing(pending.peerDeviceId)
        return PairingReady(pending, transcript, metadata.outboxGeneration, cursor.ackedSeq)
    }

    suspend fun completeConfirmed(attemptId: String, generation: String, initialCursor: Long): ConfirmedPeer {
        val ready = prepareReady(attemptId)
        check(ready.outboxGeneration == generation && ready.initialCursor == initialCursor) {
            "Mac confirmation did not exactly echo ready state"
        }
        val pending = ready.pending
        val peer = ConfirmedPeer(
            deviceId = pending.peerDeviceId,
            name = pending.peerName,
            certificateDerBase64 = pending.peerCertificateDerBase64,
            endpoint = pending.endpoint,
            pairAttemptId = pending.attemptId,
            transcriptHash = ready.transcriptHash,
            initialCursor = initialCursor,
            pairedAtWall = System.currentTimeMillis(),
        )
        identityStore.promotePending(attemptId, peer)
        identityStore.ensureTrustAssociationDependencies()
        return peer
    }

    suspend fun reject(attemptId: String) {
        identityStore.rejectPending(attemptId)
    }

    suspend fun unpair(deviceId: String, notifyPeer: Boolean = true) {
        val tombstone = identityStore.revokeToTombstone(deviceId)
        EventStoreProvider.repository(appContext).removePairing(deviceId)
        if (!notifyPeer && tombstone != null) identityStore.clearTombstone(deviceId)
    }

    suspend fun applyRemoteUnpair(
        deviceId: String,
        unpairId: String,
        initiatorId: String,
        peerId: String,
    ): AppliedUnpairReceipt {
        val receipt = identityStore.applyRemoteUnpair(deviceId, unpairId, initiatorId, peerId)
        EventStoreProvider.repository(appContext).removePairing(deviceId)
        return receipt
    }

    suspend fun reconcileCrossStore() {
        val state = identityStore.read()
        val repository = EventStoreProvider.repository(appContext)
        state.confirmedPeers.forEach { repository.ensurePairing(it.deviceId) }
        val retainedPairingRows = state.confirmedPeers.map(ConfirmedPeer::deviceId).toSet() +
            state.pendingPairings.filter { it.localConfirmed && it.peerConfirmed }.map(PendingPairing::peerDeviceId)
        repository.pairingRows().filter { row -> row.pairingId !in retainedPairingRows }
            .forEach { repository.removePairing(it.pairingId) }
    }
}

data class PairingReady(
    val pending: PendingPairing,
    val transcriptHash: String,
    val outboxGeneration: String,
    val initialCursor: Long,
)
