package dev.eko.app

import android.app.ActivityManager
import android.app.Application
import android.app.ApplicationExitInfo
import android.database.sqlite.SQLiteException
import android.os.Build
import android.os.SystemClock
import dev.eko.outbox.EventStoreFailurePolicy
import dev.eko.outbox.EventStoreProvider
import dev.eko.outbox.EventStoreResetter
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.PairingCoordinator
import dev.eko.transport.ConnectionService
import dev.eko.transport.TransportRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class EkoApplication : Application() {
    private val applicationScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun onCreate() {
        super.onCreate()
        ProcessLifetime.startedElapsed
        blockStartsAfterUserStop()
        HealthWork.schedule(this)
        applicationScope.launch {
            val identityStore = IdentityStore.get(this@EkoApplication)
            EventStoreResetter.resumeIfNeeded(this@EkoApplication, identityStore)
            try {
                EventStoreProvider.repository(this@EkoApplication).initialize()
            } catch (error: SQLiteException) {
                if (EventStoreFailurePolicy.requiresReset(error)) {
                    EventStoreResetter.reset(this@EkoApplication, identityStore)
                } else {
                    TransportRuntime.log(
                        "Event store unavailable without verified corruption; keeping data: ${error.javaClass.simpleName}",
                    )
                }
            }
            PairingCoordinator(this@EkoApplication).reconcileCrossStore()
            recordProcessExitEvidence(identityStore)
            val identity = identityStore.read()
            IdentityStore.setHasKnownPeer(this@EkoApplication, identity.hasConnectionWork)
            if (!identity.forwardingPaused && identity.hasConnectionWork) {
                ConnectionService.requestStart(this@EkoApplication)
            }
        }
    }

    private fun blockStartsAfterUserStop() {
        if (Build.VERSION.SDK_INT < 30) return
        val latest = getSystemService(ActivityManager::class.java)
            .getHistoricalProcessExitReasons(packageName, 0, 5)
            .maxByOrNull { it.timestamp } ?: return
        val recorded = getSharedPreferences("eko-process-health", MODE_PRIVATE)
            .getLong("last_exit_timestamp", 0)
        if (latest.timestamp > recorded && latest.reason == ApplicationExitInfo.REASON_USER_REQUESTED) {
            IdentityStore.setStartBlocked(this, true)
        }
    }

    private suspend fun recordProcessExitEvidence(identityStore: IdentityStore) {
        if (Build.VERSION.SDK_INT < 30) return
        val activityManager = getSystemService(ActivityManager::class.java)
        val latest = activityManager.getHistoricalProcessExitReasons(packageName, 0, 5).maxByOrNull { it.timestamp }
            ?: return
        val preferences = getSharedPreferences("eko-process-health", MODE_PRIVATE)
        if (latest.timestamp <= preferences.getLong("last_exit_timestamp", 0)) return
        preferences.edit()
            .putLong("last_exit_timestamp", latest.timestamp)
            .putInt("last_exit_reason", latest.reason)
            .commit()
        if (latest.reason == android.app.ApplicationExitInfo.REASON_USER_REQUESTED) {
            identityStore.setForwardingPaused(true)
        }
        val evidenceReasons = setOf(
            android.app.ApplicationExitInfo.REASON_CRASH,
            android.app.ApplicationExitInfo.REASON_CRASH_NATIVE,
            android.app.ApplicationExitInfo.REASON_LOW_MEMORY,
            android.app.ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE,
            android.app.ApplicationExitInfo.REASON_INITIALIZATION_FAILURE,
            android.app.ApplicationExitInfo.REASON_USER_REQUESTED,
        )
        if (latest.reason in evidenceReasons) {
            EventStoreProvider.repository(this).commitCaptureGap(
                evidence = "process_exit:${latest.reason}",
                startWall = latest.timestamp,
                endWall = System.currentTimeMillis(),
            )
        }
    }
}

object ProcessLifetime {
    val startedElapsed: Long = SystemClock.elapsedRealtime()
}
