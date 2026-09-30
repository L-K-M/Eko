package dev.eko.pairing

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import dev.eko.core.EkoJson
import dev.eko.outbox.EventStoreResetJournal
import dev.eko.outbox.PendingGenerationReset
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map
import kotlinx.serialization.SerializationException
import kotlinx.serialization.decodeFromString
import kotlinx.serialization.encodeToString

private val Context.identityDataStore by preferencesDataStore(name = "eko-identity")

class IdentityStoreCorruptException(cause: Throwable) : IllegalStateException("The identity store cannot be decoded", cause)

class IdentityStore private constructor(context: Context) : EventStoreResetJournal {
    private val appContext = context.applicationContext
    private val dataStore = appContext.identityDataStore
    val state: Flow<IdentityState> = dataStore.data.map(::decode)

    suspend fun read(): IdentityState = state.first()

    suspend fun nextConnectionEpoch(): Long {
        var epoch = 0L
        update { current ->
            epoch = Math.addExact(current.connectionEpoch, 1)
            current.copy(connectionEpoch = epoch)
        }
        return epoch
    }

    suspend fun persistCertificate(certificateDerBase64: String) = update { current ->
        val existing = current.certificateDerBase64
        check(existing == null || existing == certificateDerBase64) {
            "Keystore certificate changed without an identity reset"
        }
        current.copy(certificateDerBase64 = certificateDerBase64)
    }

    // Deliberate identity rotation (e.g. replacing a keystore key that cannot
    // sign TLS handshakes). Only legal while no peer has pinned the identity;
    // pending pairings bind the old certificate in their commitments, so they
    // are dropped with it.
    suspend fun resetIdentity(certificateDerBase64: String) = update { current ->
        check(current.confirmedPeers.isEmpty()) { "Cannot rotate an identity that peers have pinned" }
        current.copy(certificateDerBase64 = certificateDerBase64, pendingPairings = emptyList())
    }

    suspend fun savePending(pending: PendingPairing) = update { current ->
        val existing = current.pendingPairings.firstOrNull { it.attemptId == pending.attemptId }
        if (existing != null) {
            check(existing.peerDeviceId == pending.peerDeviceId &&
                existing.peerCertificateDerBase64 == pending.peerCertificateDerBase64 &&
                existing.peerName == pending.peerName && existing.endpoint == pending.endpoint && existing.method == pending.method &&
                existing.outboxGeneration == pending.outboxGeneration &&
                existing.expiresAtElapsed == pending.expiresAtElapsed && existing.bootCount == pending.bootCount &&
                compatible(existing.localNonceBase64, pending.localNonceBase64) &&
                compatible(existing.peerNonceBase64, pending.peerNonceBase64) &&
                compatible(existing.localCommitHex, pending.localCommitHex) &&
                compatible(existing.peerCommitHex, pending.peerCommitHex) &&
                compatible(existing.transcriptHash, pending.transcriptHash)) {
                "A pair attempt ID was reused with a different transcript"
            }
            current.copy(pendingPairings = current.pendingPairings.map {
                if (it.attemptId == pending.attemptId) pending.copy(
                    localConfirmed = existing.localConfirmed || pending.localConfirmed,
                    peerConfirmed = existing.peerConfirmed || pending.peerConfirmed,
                    localNonceBase64 = pending.localNonceBase64 ?: existing.localNonceBase64,
                    peerNonceBase64 = pending.peerNonceBase64 ?: existing.peerNonceBase64,
                    localCommitHex = pending.localCommitHex ?: existing.localCommitHex,
                    peerCommitHex = pending.peerCommitHex ?: existing.peerCommitHex,
                    transcriptHash = pending.transcriptHash ?: existing.transcriptHash,
                    verificationCode = pending.verificationCode ?: existing.verificationCode,
                ) else it
            })
        } else {
            check(current.pendingPairings.size < 4) { "Too many concurrent pairing attempts" }
            current.copy(pendingPairings = current.pendingPairings + pending)
        }
    }

    suspend fun markLocalConfirmed(attemptId: String) = updatePending(attemptId) { it.copy(localConfirmed = true) }

    suspend fun markPeerConfirmed(attemptId: String) = updatePending(attemptId) { it.copy(peerConfirmed = true) }

    suspend fun promotePending(attemptId: String, peer: ConfirmedPeer) = update { current ->
        val pending = current.pendingPairings.firstOrNull { it.attemptId == attemptId }
        val existing = current.confirmedPeers.firstOrNull { it.deviceId == peer.deviceId }
        if (existing != null) {
            check(existing.certificateDerBase64 == peer.certificateDerBase64) { "Peer identity pin changed" }
        } else {
            check(pending != null && pending.localConfirmed && pending.peerConfirmed) {
                "Pairing cannot be promoted before both confirmations"
            }
        }
        current.copy(
            confirmedPeers = current.confirmedPeers.filterNot { it.deviceId == peer.deviceId } + (existing ?: peer),
            pendingPairings = current.pendingPairings.filterNot { it.attemptId == attemptId },
            tombstones = current.tombstones.filterNot { it.deviceId == peer.deviceId },
            appliedUnpairReceipts = current.appliedUnpairReceipts.filterNot { it.deviceId == peer.deviceId },
        )
    }

    suspend fun rejectPending(attemptId: String) = update { current ->
        current.copy(pendingPairings = current.pendingPairings.filterNot { it.attemptId == attemptId })
    }

    suspend fun pruneExpiredPending(nowWall: Long = System.currentTimeMillis()) = update { current ->
        val bootCount = android.provider.Settings.Global.getInt(
            appContext.contentResolver,
            android.provider.Settings.Global.BOOT_COUNT,
            -1,
        )
        val elapsed = android.os.SystemClock.elapsedRealtime()
        current.copy(pendingPairings = current.pendingPairings.filter {
            it.bootCount == bootCount && it.expiresAtElapsed > elapsed && it.expiresAtWall > nowWall
        })
    }

    suspend fun revokeToTombstone(deviceId: String): RevokedPeerTombstone? {
        var tombstone: RevokedPeerTombstone? = null
        update { current ->
            val peer = current.confirmedPeers.firstOrNull { it.deviceId == deviceId } ?: return@update current
            tombstone = RevokedPeerTombstone(
                peer.deviceId,
                peer.certificateDerBase64,
                peer.endpoint,
                System.currentTimeMillis(),
                java.util.UUID.randomUUID().toString(),
            )
            current.copy(
                confirmedPeers = current.confirmedPeers.filterNot { it.deviceId == deviceId },
                tombstones = current.tombstones.filterNot { it.deviceId == deviceId } + tombstone!!,
                associations = current.associations.map { association ->
                    association.copy(pairingDependencies = association.pairingDependencies - deviceId)
                },
            )
        }
        return tombstone
    }

    suspend fun clearTombstone(deviceId: String) = update { current ->
        current.copy(tombstones = current.tombstones.filterNot { it.deviceId == deviceId })
    }

    suspend fun applyRemoteUnpair(
        deviceId: String,
        unpairId: String,
        initiatorId: String,
        peerId: String,
    ): AppliedUnpairReceipt {
        var receipt: AppliedUnpairReceipt? = null
        update { current ->
            current.appliedUnpairReceipts.firstOrNull { it.unpairId == unpairId }?.let {
                check(it.deviceId == deviceId && it.initiatorId == initiatorId && it.peerId == peerId) {
                    "Conflicting retry for an applied unpair ID"
                }
                receipt = it
                return@update current
            }
            val peer = current.confirmedPeers.firstOrNull { it.deviceId == deviceId }
            val tombstone = current.tombstones.firstOrNull { it.deviceId == deviceId }
            val certificate = peer?.certificateDerBase64 ?: tombstone?.certificateDerBase64
                ?: error("Remote unpair does not name a confirmed or tombstoned peer")
            val endpoint = peer?.endpoint ?: checkNotNull(tombstone).endpoint
            receipt = AppliedUnpairReceipt(
                deviceId = deviceId,
                certificateDerBase64 = certificate,
                endpoint = endpoint,
                unpairId = unpairId,
                initiatorId = initiatorId,
                peerId = peerId,
                appliedAtWall = System.currentTimeMillis(),
            )
            current.copy(
                confirmedPeers = current.confirmedPeers.filterNot { it.deviceId == deviceId },
                appliedUnpairReceipts = current.appliedUnpairReceipts + receipt!!,
                associations = current.associations.map { association ->
                    association.copy(pairingDependencies = association.pairingDependencies - deviceId)
                },
            )
        }
        return checkNotNull(receipt)
    }

    suspend fun clearAppliedReceipt(unpairId: String) = update { current ->
        current.copy(appliedUnpairReceipts = current.appliedUnpairReceipts.filterNot { it.unpairId == unpairId })
    }

    suspend fun updateHighestProtocol(deviceId: String, protocol: Int) = update { current ->
        current.copy(confirmedPeers = current.confirmedPeers.map { peer ->
            if (peer.deviceId == deviceId) peer.copy(highestProtocol = maxOf(peer.highestProtocol, protocol)) else peer
        })
    }

    suspend fun updateEndpoint(deviceId: String, endpoint: PeerEndpoint) = update { current ->
        current.copy(confirmedPeers = current.confirmedPeers.map { peer ->
            if (peer.deviceId == deviceId) peer.copy(endpoint = endpoint) else peer
        })
    }

    suspend fun replaceAssociations(associations: List<AssociationRecord>): Boolean {
        var changed = false
        update { current ->
            val previousIds = current.associations.map(AssociationRecord::id).toSet()
            val nextIds = associations.map(AssociationRecord::id).toSet()
            changed = previousIds != nextIds
            val dependencies = current.associations.associate { it.id to it.pairingDependencies }
            current.copy(associations = associations.map { association ->
                association.copy(pairingDependencies = association.pairingDependencies.ifEmpty {
                    dependencies[association.id].orEmpty()
                })
            })
        }
        return changed
    }

    suspend fun dependOnAssociation(associationId: Int, deviceId: String) = update { current ->
        current.copy(
            associations = current.associations.map { association ->
                if (association.id == associationId) {
                    association.copy(pairingDependencies = (association.pairingDependencies + deviceId).distinct())
                } else association
            },
            confirmedPeers = current.confirmedPeers.map { peer ->
                if (peer.deviceId == deviceId) {
                    peer.copy(associationIds = (peer.associationIds + associationId).distinct())
                } else peer
            },
        )
    }

    suspend fun ensureTrustAssociationDependencies() = update { current ->
        val trustAssociation = current.associations.firstOrNull() ?: return@update current
        val peerIds = current.confirmedPeers.map(ConfirmedPeer::deviceId)
        current.copy(
            associations = current.associations.map { association ->
                if (association.id == trustAssociation.id) {
                    association.copy(pairingDependencies = (association.pairingDependencies + peerIds).distinct())
                } else association
            },
            confirmedPeers = current.confirmedPeers.map { peer ->
                peer.copy(associationIds = (peer.associationIds + trustAssociation.id).distinct())
            },
        )
    }

    suspend fun setPresenceEnabled(associationId: Int, enabled: Boolean) = update { current ->
        current.copy(associations = current.associations.map { association ->
            if (association.id == associationId) association.copy(presenceEnabled = enabled) else association
        })
    }

    suspend fun setForwardingPaused(paused: Boolean) {
        setStartBlocked(context = appContext, blocked = paused)
        update { it.copy(forwardingPaused = paused) }
    }

    override suspend fun pendingReset(): PendingGenerationReset? = read().resetJournal?.let {
        PendingGenerationReset(it.oldGeneration, it.newGeneration, it.pairingIds)
    }

    override suspend fun beginReset(oldGeneration: String?, newGeneration: String): PendingGenerationReset {
        var result: PendingGenerationReset? = null
        update { current ->
            current.resetJournal?.let { existing ->
                result = PendingGenerationReset(existing.oldGeneration, existing.newGeneration, existing.pairingIds)
                return@update current
            }
            val pairingIds = current.confirmedPeers.map(ConfirmedPeer::deviceId)
            result = PendingGenerationReset(oldGeneration, newGeneration, pairingIds)
            current.copy(
                connectionEpoch = Math.addExact(current.connectionEpoch, 1),
                retiredGenerations = (current.retiredGenerations + listOfNotNull(oldGeneration)).distinct().takeLast(32),
                resetJournal = ResetJournalState(oldGeneration, newGeneration, pairingIds),
                pendingPairings = emptyList(),
            )
        }
        return checkNotNull(result)
    }

    override suspend fun completeReset(newGeneration: String) = update { current ->
        check(current.resetJournal?.newGeneration == newGeneration) { "Reset journal generation mismatch" }
        current.copy(resetJournal = null, currentGeneration = newGeneration)
    }

    private suspend fun updatePending(attemptId: String, transform: (PendingPairing) -> PendingPairing) = update { current ->
        check(current.pendingPairings.any { it.attemptId == attemptId }) { "Unknown pending pair attempt" }
        current.copy(pendingPairings = current.pendingPairings.map {
            if (it.attemptId == attemptId) transform(it) else it
        })
    }

    private fun compatible(existing: String?, replacement: String?): Boolean =
        existing == null || replacement == null || existing == replacement

    private suspend fun update(transform: (IdentityState) -> IdentityState) {
        dataStore.edit { preferences ->
            val current = decode(preferences)
            val next = transform(current)
            preferences[STATE] = EkoJson.encodeToString(next)
            setHasKnownPeer(appContext, next.hasConnectionWork)
        }
    }

    private fun decode(preferences: Preferences): IdentityState {
        val encoded = preferences[STATE] ?: return IdentityState()
        return try {
            EkoJson.decodeFromString(encoded)
        } catch (error: SerializationException) {
            throw IdentityStoreCorruptException(error)
        }
    }

    companion object {
        private val STATE = stringPreferencesKey("state_v1")
        private val reference = AtomicReference<IdentityStore?>()

        fun get(context: Context): IdentityStore = reference.get() ?: synchronized(this) {
            reference.get() ?: IdentityStore(context).also(reference::set)
        }

        fun isStartBlocked(context: Context): Boolean = context.applicationContext
            .getSharedPreferences("eko-start-gate", Context.MODE_PRIVATE)
            .getBoolean("blocked", false)

        fun setStartBlocked(context: Context, blocked: Boolean) {
            context.applicationContext.getSharedPreferences("eko-start-gate", Context.MODE_PRIVATE)
                .edit().putBoolean("blocked", blocked).commit()
        }

        fun hasKnownPeer(context: Context): Boolean = context.applicationContext
            .getSharedPreferences("eko-start-gate", Context.MODE_PRIVATE)
            .getBoolean("has_peer", false)

        fun setHasKnownPeer(context: Context, hasPeer: Boolean) {
            context.applicationContext.getSharedPreferences("eko-start-gate", Context.MODE_PRIVATE)
                .edit().putBoolean("has_peer", hasPeer).commit()
        }
    }
}
