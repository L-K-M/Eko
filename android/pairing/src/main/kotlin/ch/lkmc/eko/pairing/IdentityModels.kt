package dev.eko.pairing

import kotlinx.serialization.Serializable

@Serializable
data class PeerEndpoint(
    val host: String,
    val port: Int,
) {
    init {
        require(host.isNotBlank())
        require(port in 1..65_535)
    }
}

@Serializable
data class ConfirmedPeer(
    val deviceId: String,
    val name: String,
    val certificateDerBase64: String,
    val endpoint: PeerEndpoint,
    val pairAttemptId: String,
    val transcriptHash: String,
    val initialCursor: Long,
    val highestProtocol: Int = 1,
    val pairedAtWall: Long,
    val associationIds: List<Int> = emptyList(),
)

@Serializable
data class PendingPairing(
    val attemptId: String,
    val peerDeviceId: String,
    val peerName: String,
    val peerCertificateDerBase64: String,
    val endpoint: PeerEndpoint,
    val transcriptHash: String? = null,
    val method: String = "compare",
    val outboxGeneration: String,
    val expiresAtWall: Long,
    val expiresAtElapsed: Long,
    val bootCount: Int,
    val localConfirmed: Boolean = false,
    val peerConfirmed: Boolean = false,
    val localNonceBase64: String? = null,
    val peerNonceBase64: String? = null,
    val localCommitHex: String? = null,
    val peerCommitHex: String? = null,
    val verificationCode: String? = null,
)

@Serializable
data class RevokedPeerTombstone(
    val deviceId: String,
    val certificateDerBase64: String,
    val endpoint: PeerEndpoint,
    val createdAtWall: Long,
    val unpairId: String,
)

@Serializable
data class AppliedUnpairReceipt(
    val deviceId: String,
    val certificateDerBase64: String,
    val endpoint: PeerEndpoint,
    val unpairId: String,
    val initiatorId: String,
    val peerId: String,
    val appliedAtWall: Long,
)

@Serializable
data class AssociationRecord(
    val id: Int,
    val address: String? = null,
    val displayName: String? = null,
    val pairingDependencies: List<String> = emptyList(),
    val presenceEnabled: Boolean = false,
)

@Serializable
data class ResetJournalState(
    val oldGeneration: String? = null,
    val newGeneration: String,
    val pairingIds: List<String>,
)

@Serializable
data class IdentityState(
    val schemaVersion: Int = 1,
    val certificateDerBase64: String? = null,
    val connectionEpoch: Long = 0,
    val confirmedPeers: List<ConfirmedPeer> = emptyList(),
    val pendingPairings: List<PendingPairing> = emptyList(),
    val tombstones: List<RevokedPeerTombstone> = emptyList(),
    val appliedUnpairReceipts: List<AppliedUnpairReceipt> = emptyList(),
    val associations: List<AssociationRecord> = emptyList(),
    val retiredGenerations: List<String> = emptyList(),
    val resetJournal: ResetJournalState? = null,
    val currentGeneration: String? = null,
    val forwardingPaused: Boolean = false,
) {
    val hasConnectionWork: Boolean
        get() = confirmedPeers.isNotEmpty() || tombstones.isNotEmpty() || appliedUnpairReceipts.isNotEmpty()

    val hasTrustAssociation: Boolean
        get() = associations.isNotEmpty()
}
