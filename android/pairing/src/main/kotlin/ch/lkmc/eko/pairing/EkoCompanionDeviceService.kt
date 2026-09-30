package dev.eko.pairing

import android.companion.AssociationInfo
import android.companion.CompanionDeviceService
import android.companion.DevicePresenceEvent
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

data class CompanionPresence(
    val associationId: Int? = null,
    val address: String? = null,
    val present: Boolean = false,
    val event: String = "none",
    val changedAtWall: Long = 0,
)

object CompanionPresenceState {
    private val mutable = MutableStateFlow(CompanionPresence())
    val state = mutable.asStateFlow()

    internal fun update(value: CompanionPresence) {
        mutable.value = value
    }
}

@androidx.annotation.RequiresApi(31)
open class EkoCompanionDeviceService : CompanionDeviceService() {
    override fun onDeviceAppeared(address: String) {
        update(null, address, true, "appeared")
    }

    override fun onDeviceDisappeared(address: String) {
        update(null, address, false, "disappeared")
    }

    protected fun update(id: Int?, address: String?, present: Boolean, event: String) {
        CompanionPresenceState.update(
            CompanionPresence(id, address, present, event, System.currentTimeMillis()),
        )
    }
}

@androidx.annotation.RequiresApi(33)
open class EkoCompanionDeviceServiceApi33 : EkoCompanionDeviceService() {
    override fun onDeviceAppeared(associationInfo: AssociationInfo) {
        update(associationInfo.id, associationInfo.deviceMacAddress?.toString(), true, "appeared")
    }

    override fun onDeviceDisappeared(associationInfo: AssociationInfo) {
        update(associationInfo.id, associationInfo.deviceMacAddress?.toString(), false, "disappeared")
    }
}

@androidx.annotation.RequiresApi(36)
class EkoCompanionDeviceServiceApi36 : EkoCompanionDeviceServiceApi33() {
    override fun onDevicePresenceEvent(event: DevicePresenceEvent) {
        val present = event.event == DevicePresenceEvent.EVENT_BLE_APPEARED ||
            event.event == DevicePresenceEvent.EVENT_BT_CONNECTED ||
            event.event == DevicePresenceEvent.EVENT_SELF_MANAGED_APPEARED
        update(event.associationId, null, present, "presence:${event.event}")
    }
}
