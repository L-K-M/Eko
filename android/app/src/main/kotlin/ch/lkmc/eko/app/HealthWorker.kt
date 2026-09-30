package dev.eko.app

import android.content.Context
import android.os.SystemClock
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import dev.eko.capture.NotificationListenerController
import dev.eko.outbox.EventStoreProvider
import dev.eko.outbox.StoreDurability
import dev.eko.outbox.StoreHealth
import dev.eko.pairing.CdmAssociationController
import dev.eko.pairing.IdentityStore
import dev.eko.pairing.PairingCoordinator
import dev.eko.transport.ConnectionService
import java.util.concurrent.TimeUnit

class HealthWorker(
    appContext: Context,
    parameters: WorkerParameters,
) : CoroutineWorker(appContext, parameters) {
    override suspend fun doWork(): Result {
        val identityStore = IdentityStore.get(applicationContext)
        val repository = EventStoreProvider.repository(applicationContext)
        return try {
            identityStore.pruneExpiredPending()
            PairingCoordinator(applicationContext).reconcileCrossStore()
            repository.initialize()
            repository.pairingRows().forEach { repository.applyRetention(it.pairingId) }
            CdmAssociationController(
                applicationContext,
                identityStore,
            ) { NotificationListenerController.supportedRebind(applicationContext) }.inventory()
            if (NotificationListenerController.hasAccess(applicationContext) &&
                !NotificationListenerController.connected.value &&
                SystemClock.elapsedRealtime() - ProcessLifetime.startedElapsed >= LISTENER_GRACE_MS
            ) {
                NotificationListenerController.supportedRebind(applicationContext)
            }
            val identity = identityStore.read()
            if (!identity.forwardingPaused && identity.confirmedPeers.isNotEmpty()) {
                ConnectionService.requestStart(applicationContext)
            }
            if (StoreHealth.durability.value is StoreDurability.Unhealthy) Result.failure() else Result.success()
        } catch (error: Throwable) {
            Result.retry()
        }
    }

    private companion object {
        const val LISTENER_GRACE_MS = 30_000L
    }
}

object HealthWork {
    private const val PERIODIC_NAME = "eko-health-periodic"
    private const val IMMEDIATE_NAME = "eko-health-immediate"

    fun schedule(context: Context) {
        val manager = WorkManager.getInstance(context)
        manager.enqueueUniquePeriodicWork(
            PERIODIC_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            PeriodicWorkRequestBuilder<HealthWorker>(15, TimeUnit.MINUTES).build(),
        )
        manager.enqueueUniqueWork(
            IMMEDIATE_NAME,
            ExistingWorkPolicy.REPLACE,
            OneTimeWorkRequestBuilder<HealthWorker>().build(),
        )
    }
}
