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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.onStart
import kotlinx.coroutines.flow.sample
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

@OptIn(FlowPreview::class)
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
    // metadata.lastAssignedSeq advances on every committed event, so this flow ticks at
    // the capture rate. Sampling it keeps the queue-depth readout live without
    // recomposing Home once per arriving notification — it is a count, not an animation.
    private val highWaterSeq = repository.observeMetadata()
        .onStart { emit(repository.initialize()) }
        .map { it.lastAssignedSeq }
        .distinctUntilChanged()
        .sample(QUEUE_DEPTH_SAMPLE_MS)

    val home: StateFlow<HomeState> = combine(
        identityStore.state,
        highWaterSeq,
        TransportRuntime.state,
        // Observed rather than read imperatively inside the transform. The old code
        // called the suspending pairingRows() once *per peer* and then linearly searched
        // the result for that one peer — an N+1 over the same table, re-run on every
        // captured notification. pairing_cursor only changes on ack, so as a flow it
        // emits orders of magnitude less often than the outbox does.
        repository.observePairings(),
    ) { identity, lastAssignedSeq, transport, cursors ->
        val cursorsByPairing = cursors.associateBy { it.pairingId }
        HomeState(
            forwardingPaused = identity.forwardingPaused,
            peers = identity.confirmedPeers.sortedBy(ConfirmedPeer::name).map { peer ->
                val cursor = cursorsByPairing[peer.deviceId]
                val effective = cursor?.let { maxOf(it.ackedSeq + 1, it.serveFromSeq) }
                val queued = if (effective == null || effective > lastAssignedSeq) 0 else lastAssignedSeq - effective + 1
                HomePeer(peer, transport.peers[peer.deviceId] ?: PeerTransportState.Offline, queued)
            },
        )
    }
        // repository.initialize() is exactly the call EkoApplication already treats as
        // throwing, and it runs here inside the coroutine stateIn starts. viewModelScope
        // installs no CoroutineExceptionHandler, so an unopenable store used to take the
        // process down on launch — precisely when the user needs the Diagnostics screen
        // that reports it. StoreHealth.durability already carries that state; keep the
        // UI alive so it can be read.
        .catch { emit(HomeState()) }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), HomeState())

    val apps: StateFlow<List<AppWithRule>> = repository.observeApps()
        .catch { emit(emptyList()) }
        .stateIn(
            viewModelScope,
            SharingStarted.WhileSubscribed(5_000),
            emptyList(),
        )
    val captureHealth = CaptureDiagnostics.get(context).state
    val transport = TransportRuntime.state
    val storeHealth = StoreHealth.durability

    private val associationController by lazy { CdmAssociationController(context) }

    init {
        refreshSystemChecks()
        viewModelScope.launch {
            runCatching { associationController.inventory() }
        }
    }

    /**
     * Re-read the five system permission states.
     *
     * Every one of these is a binder round-trip — NotificationManagerService,
     * DeviceIdleController, the location provider, the package manager — and the
     * SharedPreferences read blocks on parsing XML the first time. This runs from the
     * ViewModel's init, from `MainActivity.onResume` on *every* resume, and from three
     * activity-result callbacks, which is to say: constantly, during onboarding, while
     * the user bounces to Settings and back. Doing it on the main thread cost a dropped
     * frame every time. Off the main thread, publishing the result at the end.
     */
    fun refreshSystemChecks() {
        viewModelScope.launch(Dispatchers.IO) {
            val postAllowed = Build.VERSION.SDK_INT < 33 ||
                ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
            mutableChecks.value = SystemChecks(
                managedProfile = ManagedProfileGuard.isManagedProfile(context),
                notificationAccess = NotificationListenerController.hasAccess(context),
                postNotifications = postAllowed,
                batteryExempt = context.getSystemService(PowerManager::class.java).isIgnoringBatteryOptimizations(context.packageName),
                locationEnabled = associationController.isLocationEnabled(),
                recentExitReason = context.getSharedPreferences("eko-process-health", android.content.Context.MODE_PRIVATE)
                    .takeIf { it.contains("last_exit_reason") }
                    ?.getInt("last_exit_reason", 0),
            )
        }
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

    private companion object {
        const val QUEUE_DEPTH_SAMPLE_MS = 500L
    }
}
