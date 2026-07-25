package dev.eko.app

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import dev.eko.capture.CaptureDiagnostics
import dev.eko.capture.NotificationListenerController
import dev.eko.outbox.AppRuleEntity
import dev.eko.outbox.AppWithRule
import dev.eko.outbox.EventStoreProvider
import dev.eko.outbox.MetadataEntity
import dev.eko.outbox.StoreHealth
import dev.eko.pairing.CdmAssociationController
import dev.eko.pairing.ConfirmedPeer
import dev.eko.pairing.IdentityState
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.ManagedProfileGuard
import dev.eko.pairing.PairingCoordinator
import dev.eko.pairing.PeerEndpoint
import dev.eko.transport.ConnectionService
import dev.eko.transport.LanPairingClient
import dev.eko.transport.PairingConnectionRequest
import dev.eko.transport.PairingHandle
import dev.eko.transport.PeerTransportState
import dev.eko.transport.TransportRuntime
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class SystemChecks(
    val managedProfile: Boolean = false,
    val notificationAccess: Boolean = false,
    val postNotifications: Boolean = false,
    val batteryExempt: Boolean = false,
    val locationEnabled: Boolean = false,
    val recentExitReason: Int? = null,
)

data class HomePeer(
    val peer: ConfirmedPeer,
    val status: PeerTransportState,
    val queuedEvents: Long,
)

data class HomeState(
    val forwardingPaused: Boolean = false,
    val peers: List<HomePeer> = emptyList(),
)

sealed interface PairingUiState {
    data object Idle : PairingUiState
    data object Connecting : PairingUiState
    data class Verify(val peerName: String, val code: String, val attemptId: String) : PairingUiState
    data class Success(val peerName: String) : PairingUiState
    data class Failed(val detail: String) : PairingUiState
}

class EkoViewModel(application: Application) : AndroidViewModel(application) {
    private val context = application.applicationContext
    private val identityStore = IdentityStore.get(context)
    private val repository = EventStoreProvider.repository(context)
    private val mutableChecks = MutableStateFlow(SystemChecks())
    val checks: StateFlow<SystemChecks> = mutableChecks
    private val mutablePairing = MutableStateFlow<PairingUiState>(PairingUiState.Idle)
    val pairing: StateFlow<PairingUiState> = mutablePairing
    private var pairingHandle: PairingHandle? = null
    private var pairingExpiryJob: kotlinx.coroutines.Job? = null

    val identity: StateFlow<IdentityState> = identityStore.state.stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        IdentityState(),
    )
    private val metadata = repository.observeMetadata().onStart { emit(repository.initialize()) }
    val home: StateFlow<HomeState> = combine(identityStore.state, metadata, TransportRuntime.state) {
            identity, metadata, transport ->
        HomeState(
            forwardingPaused = identity.forwardingPaused,
            peers = identity.confirmedPeers.sortedBy(ConfirmedPeer::name).map { peer ->
                val cursor = runCatching { repository.pairingRows().firstOrNull { it.pairingId == peer.deviceId } }.getOrNull()
                val effective = cursor?.let { maxOf(it.ackedSeq + 1, it.serveFromSeq) }
                val queued = if (effective == null || effective > metadata.lastAssignedSeq) 0 else metadata.lastAssignedSeq - effective + 1
                HomePeer(peer, transport.peers[peer.deviceId] ?: PeerTransportState.Offline, queued)
            },
        )
    }.stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), HomeState())

    val apps: StateFlow<List<AppWithRule>> = repository.observeApps().stateIn(
        viewModelScope,
        SharingStarted.WhileSubscribed(5_000),
        emptyList(),
    )
    val captureHealth = CaptureDiagnostics.get(context).state
    val transport = TransportRuntime.state
    val storeHealth = StoreHealth.durability

    init {
        refreshSystemChecks()
        viewModelScope.launch {
            runCatching { CdmAssociationController(context).inventory() }
        }
    }

    fun refreshSystemChecks() {
        val postAllowed = Build.VERSION.SDK_INT < 33 ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
        mutableChecks.value = SystemChecks(
            managedProfile = ManagedProfileGuard.isManagedProfile(context),
            notificationAccess = NotificationListenerController.hasAccess(context),
            postNotifications = postAllowed,
            batteryExempt = context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName),
            locationEnabled = CdmAssociationController(context).isLocationEnabled(),
            recentExitReason = context.getSharedPreferences("eko-process-health", android.content.Context.MODE_PRIVATE)
                .takeIf { it.contains("last_exit_reason") }
                ?.getInt("last_exit_reason", 0),
        )
    }

    fun startPairing(host: String, port: String, fingerprint: String?, token: String?, resumeAttemptId: String? = null) {
        if (ManagedProfileGuard.isManagedProfile(context)) {
            mutablePairing.value = PairingUiState.Failed(context.getString(R.string.managed_profile_title))
            return
        }
        viewModelScope.launch {
            mutablePairing.value = PairingUiState.Connecting
            try {
                val parsedPort = port.toInt()
                val normalizedFingerprint = fingerprint?.trim()?.takeIf(String::isNotEmpty)?.lowercase()
                if (normalizedFingerprint != null) require(Regex("^[0-9a-f]{64}$").matches(normalizedFingerprint))
                val handle = LanPairingClient(context).connect(
                    PairingConnectionRequest(
                        endpoint = PeerEndpoint(host.trim(), parsedPort),
                        expectedFingerprint = normalizedFingerprint,
                        oneTimeToken = token?.trim()?.takeIf(String::isNotEmpty),
                        resumeAttemptId = resumeAttemptId,
                    ),
                )
                pairingHandle = handle
                watchPairingExpiry(handle)
                mutablePairing.value = PairingUiState.Verify(handle.peerName, handle.verificationCode, handle.attemptId)
            } catch (error: Throwable) {
                mutablePairing.value = PairingUiState.Failed(error.message ?: error.javaClass.simpleName)
            }
        }
    }

    private fun watchPairingExpiry(handle: PairingHandle) {
        pairingExpiryJob?.cancel()
        pairingExpiryJob = viewModelScope.launch {
            val remaining = handle.expiresAtElapsed - SystemClock.elapsedRealtime()
            if (remaining > 0) delay(remaining)
            if (pairingHandle === handle) {
                pairingHandle = null
                handle.expire()
                mutablePairing.value = PairingUiState.Failed(context.getString(R.string.pair_expired))
            }
        }
    }

    fun confirmPairing(accepted: Boolean) {
        val handle = pairingHandle ?: return
        viewModelScope.launch {
            try {
                val peer = handle.confirm(accepted)
                pairingHandle = null
                pairingExpiryJob?.cancel()
                mutablePairing.value = when {
                    peer != null -> {
                        ConnectionService.requestStart(context)
                        PairingUiState.Success(peer.name)
                    }
                    handle.isExpired -> PairingUiState.Failed(context.getString(R.string.pair_expired))
                    else -> PairingUiState.Idle
                }
            } catch (error: Throwable) {
                mutablePairing.value = PairingUiState.Failed(error.message ?: error.javaClass.simpleName)
            }
        }
    }

    fun clearPairingState() {
        pairingExpiryJob?.cancel()
        pairingHandle?.close()
        pairingHandle = null
        mutablePairing.value = PairingUiState.Idle
    }

    fun setForwardingPaused(paused: Boolean) {
        viewModelScope.launch {
            identityStore.setForwardingPaused(paused)
            if (!paused) ConnectionService.requestStart(context)
        }
    }

    fun updateRule(app: AppWithRule, enabled: Boolean = app.enabled, ongoing: Boolean = app.includeOngoing, otp: Boolean = app.otpHint) {
        viewModelScope.launch {
            repository.updateAppRule(AppRuleEntity(app.packageName, app.userId, enabled, ongoing, otp))
            if (enabled) NotificationListenerController.reconcileActive()
        }
    }

    fun unpair(deviceId: String, notifyPeer: Boolean = true) {
        viewModelScope.launch {
            PairingCoordinator(context).unpair(deviceId, notifyPeer)
            val controller = CdmAssociationController(context, identityStore) {
                NotificationListenerController.supportedRebind(context)
            }
            controller.inventory().forEach { controller.removeIfUnused(it.id) }
        }
    }

    fun setPresenceObservation(associationId: Int, enabled: Boolean) {
        viewModelScope.launch {
            runCatching { CdmAssociationController(context, identityStore).setPresenceObservation(associationId, enabled) }
        }
    }

    fun forgetAppliedReceipt(unpairId: String) {
        viewModelScope.launch { identityStore.clearAppliedReceipt(unpairId) }
    }

    fun repairListener() {
        viewModelScope.launch { NotificationListenerController.supportedRebind(context) }
    }

    override fun onCleared() {
        pairingExpiryJob?.cancel()
        pairingHandle?.close()
        super.onCleared()
    }
}
