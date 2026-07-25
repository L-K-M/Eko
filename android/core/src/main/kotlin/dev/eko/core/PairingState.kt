package dev.eko.core

sealed interface PairingPhase {
    data object Connecting : PairingPhase
    data object TlsAuthenticated : PairingPhase
    data object CommitSent : PairingPhase
    data object CommitExchanged : PairingPhase
    data class AwaitingConfirmation(val code: String) : PairingPhase
    data object LocalConfirmed : PairingPhase
    data object Confirmed : PairingPhase
    data class Rejected(val reason: String) : PairingPhase
    data object Expired : PairingPhase
}

sealed interface PairingAction {
    data object TlsReady : PairingAction
    data object LocalCommitSent : PairingAction
    data object PeerCommitReceived : PairingAction
    data class RevealVerified(val code: String) : PairingAction
    data object ConfirmLocal : PairingAction
    data object ConfirmPeer : PairingAction
    data class Reject(val reason: String) : PairingAction
    data object Expire : PairingAction
}

data class PairingMachine(
    val attemptId: String,
    val expiresAtMillis: Long,
    val phase: PairingPhase = PairingPhase.Connecting,
    val peerConfirmed: Boolean = false,
) {
    fun reduce(action: PairingAction, nowMillis: Long): PairingMachine {
        if (phase is PairingPhase.Confirmed || phase is PairingPhase.Rejected || phase is PairingPhase.Expired) {
            return this
        }
        if (nowMillis >= expiresAtMillis || action is PairingAction.Expire) {
            return copy(phase = PairingPhase.Expired)
        }
        return when (action) {
            PairingAction.TlsReady -> requirePhase<PairingPhase.Connecting>().copy(phase = PairingPhase.TlsAuthenticated)
            PairingAction.LocalCommitSent -> requirePhase<PairingPhase.TlsAuthenticated>().copy(phase = PairingPhase.CommitSent)
            PairingAction.PeerCommitReceived -> requirePhase<PairingPhase.CommitSent>().copy(phase = PairingPhase.CommitExchanged)
            is PairingAction.RevealVerified -> requirePhase<PairingPhase.CommitExchanged>()
                .copy(phase = PairingPhase.AwaitingConfirmation(action.code))
            PairingAction.ConfirmLocal -> {
                require(phase is PairingPhase.AwaitingConfirmation) { "Local confirmation is out of order" }
                copy(phase = if (peerConfirmed) PairingPhase.Confirmed else PairingPhase.LocalConfirmed)
            }
            PairingAction.ConfirmPeer -> when (phase) {
                is PairingPhase.AwaitingConfirmation -> copy(peerConfirmed = true)
                PairingPhase.LocalConfirmed -> copy(phase = PairingPhase.Confirmed, peerConfirmed = true)
                else -> throw IllegalStateException("Peer confirmation is out of order")
            }
            is PairingAction.Reject -> copy(phase = PairingPhase.Rejected(action.reason))
            PairingAction.Expire -> error("Handled above")
        }
    }

    private inline fun <reified T : PairingPhase> requirePhase(): PairingMachine {
        require(phase is T) { "Expected ${T::class.simpleName}, found ${phase::class.simpleName}" }
        return this
    }
}
