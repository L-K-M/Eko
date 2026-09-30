package dev.eko.capture

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.core.app.NotificationManagerCompat
import java.lang.ref.WeakReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.filter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

object NotificationListenerController {
    private val componentState = MutableStateFlow(false)
    val connected = componentState.asStateFlow()
    private val reconciliationState = MutableStateFlow(false)
    val reconciled = reconciliationState.asStateFlow()
    private var listener = WeakReference<EkoNotificationListener>(null)

    internal fun onConnected(instance: EkoNotificationListener) {
        listener = WeakReference(instance)
        componentState.value = true
        reconciliationState.value = false
    }

    internal fun onDisconnected(instance: EkoNotificationListener) {
        if (listener.get() === instance) listener.clear()
        componentState.value = false
        reconciliationState.value = false
    }

    internal fun onReconciled(instance: EkoNotificationListener) {
        if (listener.get() === instance && componentState.value) reconciliationState.value = true
    }

    fun hasAccess(context: Context): Boolean {
        val component = component(context)
        return if (Build.VERSION.SDK_INT >= 27) {
            context.getSystemService(NotificationManager::class.java)
                .isNotificationListenerAccessGranted(component)
        } else {
            context.packageName in NotificationManagerCompat.getEnabledListenerPackages(context)
        }
    }

    fun settingsIntent(context: Context): Intent = if (Build.VERSION.SDK_INT >= 30) {
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS).apply {
            // The extra's contract is the FLATTENED component string; passing
            // the ComponentName Parcelable makes the detail screen finish
            // immediately, bouncing the user straight back to the app.
            putExtra(
                Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                component(context).flattenToString(),
            )
        }
    } else {
        Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
    }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    suspend fun supportedRebind(context: Context) {
        val component = component(context)
        val active = listener.get()
        if (active != null && componentState.value) {
            active.requestUnbind()
            withTimeoutOrNull(5_000) { connected.filter { !it }.first() }
        }
        android.service.notification.NotificationListenerService.requestRebind(component)
    }

    fun dismiss(key: String): Boolean {
        val active = listener.get() ?: return false
        active.cancelFromPeer(key)
        return true
    }

    fun reconcileActive(): Boolean {
        val active = listener.get() ?: return false
        active.reconcileFromApp()
        return true
    }

    private fun component(context: Context) = ComponentName(context, EkoNotificationListener::class.java)
}
