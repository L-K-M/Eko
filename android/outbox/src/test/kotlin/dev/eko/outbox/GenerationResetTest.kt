package dev.eko.outbox

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.eko.core.DndDescriptor
import dev.eko.core.NotificationContent
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class GenerationResetTest {
    @Test
    fun `journaled replacement never relabels old rows and rehydrates peers at zero`() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.deleteDatabase(EventStoreProvider.DATABASE_NAME)
        val repository = EventStoreProvider.repository(context)
        repository.initialize("old-generation")
        repository.ensurePairing("mac")
        repository.commitNotification(
            NotificationSnapshot(
                key = "key",
                postedAt = 1,
                userId = 0,
                packageName = "example.app",
                appLabel = "Example",
                category = "msg",
                content = NotificationContent(text = "message", isClearable = true, isGroupSummary = false),
                dnd = DndDescriptor("all", false),
                ongoing = false,
            ),
        )
        val journal = MemoryJournal(listOf("mac"))

        val generation = EventStoreResetter.reset(context, journal)
        val replacement = EventStoreProvider.repository(context)

        assertEquals(generation, replacement.initialize().outboxGeneration)
        assertEquals(0, replacement.initialize().lastAssignedSeq)
        assertEquals(emptyList<OutboxEventEntity>(), replacement.eventsAfter(0))
        assertEquals(0, replacement.pairingRows().single().ackedSeq)
        assertEquals(1, replacement.pairingRows().single().serveFromSeq)
        assertNull(journal.pendingReset())
    }

    @Test
    fun `reset waits for in-flight writer work holding the reset lock`() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.deleteDatabase(EventStoreProvider.DATABASE_NAME)
        val repository = EventStoreProvider.repository(context)
        repository.initialize("lock-generation")
        val journal = MemoryJournal(emptyList())
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val holder = async {
            EventStoreResetLock.withResetLock {
                entered.complete(Unit)
                release.await()
            }
        }
        entered.await()

        val reset = async(Dispatchers.IO) { EventStoreResetter.reset(context, journal) }
        val deadline = System.currentTimeMillis() + 10_000
        while (journal.pendingReset() == null) {
            check(System.currentTimeMillis() < deadline) { "reset never reached its journal" }
            Thread.sleep(10)
        }
        assertTrue("replacement must wait for the in-flight writer", reset.isActive)

        release.complete(Unit)
        val generation = reset.await()
        holder.await()

        assertEquals(generation, EventStoreProvider.repository(context).initialize().outboxGeneration)
        assertNull(journal.pendingReset())
    }

    @Test
    fun `reset lock serializes writer work and replacement`() = runTest {
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val events = mutableListOf<String>()
        val holder = async {
            EventStoreResetLock.withResetLock {
                events += "writer-enter"
                entered.complete(Unit)
                release.await()
                events += "writer-exit"
            }
        }
        entered.await()

        val replacement = async {
            EventStoreResetLock.withResetLock { events += "replace" }
        }
        runCurrent()
        assertEquals(listOf("writer-enter"), events)

        release.complete(Unit)
        holder.await()
        replacement.await()

        assertEquals(listOf("writer-enter", "writer-exit", "replace"), events)
    }

    private class MemoryJournal(private val peers: List<String>) : EventStoreResetJournal {
        @Volatile
        private var pending: PendingGenerationReset? = null
        override suspend fun pendingReset() = pending
        override suspend fun beginReset(oldGeneration: String?, newGeneration: String): PendingGenerationReset =
            PendingGenerationReset(oldGeneration, newGeneration, peers).also { pending = it }
        override suspend fun completeReset(newGeneration: String) {
            check(pending?.newGeneration == newGeneration)
            pending = null
        }
    }
}
