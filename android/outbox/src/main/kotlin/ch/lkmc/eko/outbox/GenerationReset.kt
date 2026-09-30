package dev.eko.outbox

import android.content.Context
import java.util.UUID
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class PendingGenerationReset(
    val oldGeneration: String?,
    val newGeneration: String,
    val pairingIds: List<String>,
)

interface EventStoreResetJournal {
    suspend fun pendingReset(): PendingGenerationReset?
    suspend fun beginReset(oldGeneration: String?, newGeneration: String): PendingGenerationReset
    suspend fun completeReset(newGeneration: String)
}

object EventStoreResetter {
    private val mutex = Mutex()

    suspend fun resumeIfNeeded(context: Context, journal: EventStoreResetJournal): Boolean = mutex.withLock {
        val pending = journal.pendingReset() ?: return@withLock false
        replace(context.applicationContext, pending, journal)
        true
    }

    suspend fun reset(context: Context, journal: EventStoreResetJournal): String = mutex.withLock {
        val repository = EventStoreProvider.repository(context)
        val oldGeneration = runCatching { repository.initialize().outboxGeneration }.getOrNull()
        val pending = journal.beginReset(oldGeneration, UUID.randomUUID().toString())
        replace(context.applicationContext, pending, journal)
        pending.newGeneration
    }

    private suspend fun replace(
        context: Context,
        pending: PendingGenerationReset,
        journal: EventStoreResetJournal,
    ) = EventStoreResetLock.withResetLock {
        EventStoreProvider.closeAndDelete(context)
        val repository = EventStoreProvider.repository(context)
        val metadata = repository.initialize(pending.newGeneration)
        check(metadata.outboxGeneration == pending.newGeneration) { "Replacement database generation mismatch" }
        repository.rehydratePairings(pending.pairingIds)
        journal.completeReset(pending.newGeneration)
    }
}
