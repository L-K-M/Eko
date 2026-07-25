package dev.eko.pairing

import android.bluetooth.le.ScanFilter
import android.companion.AssociationRequest
import android.companion.BluetoothLeDeviceFilter
import android.companion.CompanionDeviceManager
import android.companion.WifiDeviceFilter
import android.content.Context
import android.content.Intent
import android.content.IntentSender
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.provider.Settings
import java.util.UUID
import java.util.regex.Pattern
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.launch

sealed interface AssociationEvent {
    data class Prompt(val intentSender: IntentSender) : AssociationEvent
    data class Created(val association: AssociationRecord) : AssociationEvent
    data class Failed(val reason: String) : AssociationEvent
}

class CdmAssociationController(
    context: Context,
    private val identityStore: IdentityStore = IdentityStore.get(context),
    private val afterMutation: suspend () -> Unit = {},
) {
    private val appContext = context.applicationContext
    private val manager = appContext.getSystemService(CompanionDeviceManager::class.java)

    fun requestBle(serviceUuid: UUID, watchProfile: Boolean = false): Flow<AssociationEvent> {
        val filter = BluetoothLeDeviceFilter.Builder()
            .setScanFilter(ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceUuid)).build())
            .build()
        val builder = AssociationRequest.Builder().addDeviceFilter(filter).setSingleDevice(false)
        if (watchProfile) {
            if (Build.VERSION.SDK_INT >= 31) {
                builder.setDeviceProfile(AssociationRequest.DEVICE_PROFILE_WATCH)
            } else {
                throw IllegalStateException("Watch-profile associations require Android 12")
            }
        }
        return associate(builder.build())
    }

    fun requestWifiFallback(): Flow<AssociationEvent> {
        val filter = WifiDeviceFilter.Builder().setNamePattern(Pattern.compile(".*")).build()
        return associate(AssociationRequest.Builder().addDeviceFilter(filter).setSingleDevice(false).build())
    }

    fun isLocationEnabled(): Boolean = if (Build.VERSION.SDK_INT >= 28) {
        appContext.getSystemService(LocationManager::class.java).isLocationEnabled
    } else {
        @Suppress("DEPRECATION")
        android.provider.Settings.Secure.getInt(
            appContext.contentResolver,
            android.provider.Settings.Secure.LOCATION_MODE,
            android.provider.Settings.Secure.LOCATION_MODE_OFF,
        ) != android.provider.Settings.Secure.LOCATION_MODE_OFF
    }

    fun locationSettingsIntent(): Intent = Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    suspend fun inventory(): List<AssociationRecord> {
        val records = if (Build.VERSION.SDK_INT >= 33) {
            Api33Cdm.inventory(manager)
        } else {
            @Suppress("DEPRECATION")
            manager.associations.map { address -> AssociationRecord(id = legacyId(address), address = address) }
        }
        val changed = reconcileInventory(records)
        if (changed) afterMutation()
        return identityStore.read().associations
    }

    internal suspend fun reconcileInventory(records: List<AssociationRecord>): Boolean {
        val changed = identityStore.replaceAssociations(records)
        identityStore.ensureTrustAssociationDependencies()
        return changed
    }

    suspend fun associationResultCompleted(): List<AssociationRecord> = inventory()

    suspend fun removeIfUnused(associationId: Int): Boolean {
        val state = identityStore.read()
        val association = state.associations.firstOrNull { it.id == associationId } ?: return false
        if (association.pairingDependencies.isNotEmpty()) return false
        if (state.confirmedPeers.isNotEmpty() && state.associations.size <= 1) return false
        if (Build.VERSION.SDK_INT >= 33) {
            Api33Cdm.disassociate(manager, associationId)
        } else {
            @Suppress("DEPRECATION")
            manager.disassociate(association.address ?: return false)
        }
        inventory()
        return true
    }

    suspend fun setPresenceObservation(associationId: Int, enabled: Boolean) {
        val association = identityStore.read().associations.firstOrNull { it.id == associationId }
            ?: error("Unknown CDM association")
        if (Build.VERSION.SDK_INT >= 36) {
            Api36Presence.set(manager, associationId, enabled)
        } else if (Build.VERSION.SDK_INT >= 31) {
            val address = association.address ?: error("This Android release needs an association address for presence")
            @Suppress("DEPRECATION")
            if (enabled) manager.startObservingDevicePresence(address) else manager.stopObservingDevicePresence(address)
        } else if (enabled) {
            error("Companion presence observation requires Android 12 or newer")
        }
        identityStore.setPresenceEnabled(associationId, enabled)
    }

    private fun associate(request: AssociationRequest): Flow<AssociationEvent> = callbackFlow {
        val prompt: (IntentSender) -> Unit = { sender ->
            trySend(AssociationEvent.Prompt(sender))
            close()
        }
        val failure: (String) -> Unit = { reason ->
            trySend(AssociationEvent.Failed(reason))
            close()
        }
        if (Build.VERSION.SDK_INT >= 33) {
            val callback = Api33AssociationCallback(prompt, failure) { association ->
                launch {
                    identityStore.replaceAssociations(inventoryFromSystem())
                    identityStore.ensureTrustAssociationDependencies()
                    afterMutation()
                    trySend(AssociationEvent.Created(association))
                    close()
                }
            }
            Api33Cdm.associate(manager, request, appContext.mainExecutor, callback)
        } else {
            val callback = LegacyAssociationCallback(prompt, failure)
            @Suppress("DEPRECATION")
            manager.associate(request, callback, Handler(Looper.getMainLooper()))
        }
        awaitClose { }
    }

    private fun inventoryFromSystem(): List<AssociationRecord> = if (Build.VERSION.SDK_INT >= 33) {
        Api33Cdm.inventory(manager)
    } else {
        @Suppress("DEPRECATION")
        manager.associations.map { AssociationRecord(legacyId(it), it) }
    }

    private fun legacyId(address: String): Int = address.lowercase().hashCode()
}

private open class LegacyAssociationCallback(
    private val prompt: (IntentSender) -> Unit,
    private val failure: (String) -> Unit,
) : CompanionDeviceManager.Callback() {
    @Suppress("DEPRECATION")
    override fun onDeviceFound(chooserLauncher: IntentSender) = prompt(chooserLauncher)

    override fun onFailure(error: CharSequence?) = failure(error?.toString() ?: "Companion association failed")
}

@androidx.annotation.RequiresApi(33)
private class Api33AssociationCallback(
    prompt: (IntentSender) -> Unit,
    failure: (String) -> Unit,
    private val created: (AssociationRecord) -> Unit,
) : LegacyAssociationCallback(prompt, failure) {
    override fun onAssociationPending(intentSender: IntentSender) = super.onDeviceFound(intentSender)

    override fun onAssociationCreated(associationInfo: android.companion.AssociationInfo) {
        created(Api33Cdm.record(associationInfo))
    }
}

@androidx.annotation.RequiresApi(33)
private object Api33Cdm {
    fun inventory(manager: CompanionDeviceManager): List<AssociationRecord> =
        manager.myAssociations.map(::record)

    fun record(info: android.companion.AssociationInfo) = AssociationRecord(
        id = info.id,
        address = info.deviceMacAddress?.toString(),
        displayName = info.displayName?.toString(),
    )

    fun associate(
        manager: CompanionDeviceManager,
        request: AssociationRequest,
        executor: java.util.concurrent.Executor,
        callback: CompanionDeviceManager.Callback,
    ) = manager.associate(request, executor, callback)

    fun disassociate(manager: CompanionDeviceManager, associationId: Int) = manager.disassociate(associationId)
}

@androidx.annotation.RequiresApi(36)
private object Api36Presence {
    fun set(manager: CompanionDeviceManager, associationId: Int, enabled: Boolean) {
        val request = android.companion.ObservingDevicePresenceRequest.Builder()
            .setAssociationId(associationId)
            .build()
        if (enabled) manager.startObservingDevicePresence(request) else manager.stopObservingDevicePresence(request)
    }
}
