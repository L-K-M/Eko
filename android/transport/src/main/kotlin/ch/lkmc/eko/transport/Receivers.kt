package dev.eko.transport

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import dev.eko.pairing.IdentityStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class BootAndUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
            ConnectionService.requestStart(context)
        }
    }
}

class TransportActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val paused = when (intent.action) {
            ConnectionService.ACTION_PAUSE -> true
            ConnectionService.ACTION_RESUME -> false
            else -> return
        }
        val pending = goAsync()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            try {
                IdentityStore.get(context).setForwardingPaused(paused)
                if (!paused) ConnectionService.requestStart(context)
            } finally {
                pending.finish()
            }
        }
    }
}
