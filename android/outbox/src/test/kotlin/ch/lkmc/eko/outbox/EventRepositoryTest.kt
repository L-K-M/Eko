package dev.eko.outbox

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import dev.eko.core.DndDescriptor
import dev.eko.core.EventKind
import dev.eko.core.NotificationContent
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class EventRepositoryTest {
    private lateinit var database: EventDatabase
    private lateinit var repository: EventRepository

    @Before
    fun setUp() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, EventDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        repository = EventRepository(database, BootAwareClock(context))
    }

    @After
    fun tearDown() {
        database.close()
    }

    @Test
    fun `capture transaction advances durable high-water and active state together`() = runTest {
        repository.initialize("generation")
        repository.ensurePairing("mac")

        val posted = repository.commitNotification(snapshot("key", "first"))
        val repeated = repository.commitNotification(snapshot("key", "first"))
        val updated = repository.commitNotification(snapshot("key", "second"))
        val removed = repository.commitRemoval("key", reason = 2)

        assertEquals(CaptureCommit.Committed(1, EventKind.POSTED), posted)
        assertEquals(CaptureCommit.Committed(2, EventKind.UPDATED), repeated)
        assertEquals(CaptureCommit.Committed(3, EventKind.UPDATED), updated)
        assertEquals(CaptureCommit.Committed(4, EventKind.REMOVED), removed)
        assertEquals(4, repository.initialize().lastAssignedSeq)
        assertTrue(database.active().all().isEmpty())
        assertEquals(listOf(1L, 2L, 3L, 4L), repository.eventsAfter(0).map { it.seq })
    }

    @Test
    fun `per-pair floor records a gap before global pruning`() = runTest {
        repository.initialize("generation")
        repository.ensurePairing("mac-a", retentionCount = 3)
        repeat(5) { repository.commitNotification(snapshot("a-$it", "$it")) }
        repository.ensurePairing("mac-b", retentionCount = 20)
        repeat(5) { repository.commitNotification(snapshot("b-$it", "$it")) }

        repository.applyRetention("mac-a")
        val a = repository.backlog("mac-a", peerCursor = 0)
        val b = repository.backlog("mac-b", peerCursor = 5)

        assertEquals(8, a.replayFromSeq)
        assertEquals(1L..7L, a.gaps.single().fromSeq..a.gaps.single().toSeq)
        assertEquals((8L..10L).toList(), a.eventSeqs)
        assertEquals((6L..10L).toList(), b.eventSeqs)

        repository.acknowledge("mac-b", seq = 7, highestAuthorized = 10)
        assertEquals((8L..10L).toList(), repository.eventsAfter(0).map { it.seq })
    }

    @Test
    fun `new pairing starts at high-water and cannot fetch pre-pair history`() = runTest {
        repository.initialize("generation")
        repeat(4) { repository.commitNotification(snapshot("pre-$it", "$it")) }
        val cursor = repository.ensurePairing("new-mac")
        repository.commitNotification(snapshot("after", "visible"))

        assertEquals(4, cursor.ackedSeq)
        assertEquals(5, cursor.serveFromSeq)
        assertEquals(listOf(5L), repository.backlog("new-mac", 4).eventSeqs)
    }

    @Test
    fun `reconciliation emits removals additions and changed content in one sequence`() = runTest {
        repository.initialize("generation")
        repository.ensurePairing("mac")
        repository.commitNotification(snapshot("gone", "old"))
        repository.commitNotification(snapshot("changed", "old"))

        val commits = repository.reconcile(
            listOf(snapshot("changed", "new"), snapshot("new", "posted")),
        )

        assertEquals(listOf(EventKind.REMOVED, EventKind.UPDATED, EventKind.POSTED), commits.map { it.kind })
        assertEquals(listOf(3L, 4L, 5L), commits.map { it.seq })
        assertEquals(setOf("changed", "new"), database.active().all().map { it.key }.toSet())
    }

    @Test
    fun `generation and high-water never derive from remaining rows`() = runTest {
        repository.initialize("generation")
        repository.ensurePairing("mac")
        repeat(3) { repository.commitNotification(snapshot("key-$it", "$it")) }
        repository.acknowledge("mac", 3, highestAuthorized = 3)

        assertTrue(repository.eventsAfter(0).isEmpty())
        assertEquals(3, repository.initialize().lastAssignedSeq)
        assertNotEquals(0, repository.initialize().lastAssignedSeq)
    }

    @Test
    fun `ack cannot regress or authorize unsent positions`() = runTest {
        repository.initialize("generation")
        repository.ensurePairing("mac")
        repeat(3) { repository.commitNotification(snapshot("key-$it", "$it")) }
        repository.acknowledge("mac", 2, highestAuthorized = 2)

        assertThrows(InvalidAcknowledgementException::class.java) {
            kotlinx.coroutines.runBlocking { repository.acknowledge("mac", 1, highestAuthorized = 3) }
        }
        assertThrows(InvalidAcknowledgementException::class.java) {
            kotlinx.coroutines.runBlocking { repository.acknowledge("mac", 3, highestAuthorized = 2) }
        }
    }

    @Test
    fun `replay clips stored gap spans to the requested cursor suffix`() = runTest {
        repository.initialize("generation")
        repository.ensurePairing("mac", retentionCount = 3)
        repeat(10) { repository.commitNotification(snapshot("key-$it", "$it")) }
        repository.applyRetention("mac")

        val regressed = repository.backlog("mac", peerCursor = 4)
        assertEquals(1, regressed.gaps.size)
        assertEquals(5L, regressed.gaps.single().fromSeq)
        assertEquals(7L, regressed.gaps.single().toSeq)
        assertEquals((8L..10L).toList(), regressed.eventSeqs)

        repository.setRetention("mac", ageMs = 3_600_000, count = 1)
        repository.applyRetention("mac")
        val wide = repository.backlog("mac", peerCursor = 8)
        assertEquals(listOf(9L..9L), wide.gaps.map { it.fromSeq..it.toSeq })
        assertEquals(listOf(10L), wide.eventSeqs)
        assertTrue(wide.gaps.zipWithNext().all { (a, b) -> a.toSeq < b.fromSeq })
        assertTrue(wide.gaps.all { it.fromSeq >= 9 })
    }

    @Test
    fun `replayPage returns pinned rows and refuses a hole left by retention`() = runTest {
        repository.initialize("generation")
        repository.ensurePairing("mac")
        repeat(4) { repository.commitNotification(snapshot("key-$it", "$it")) }
        val snapshot = repository.backlog("mac", peerCursor = 0)

        assertEquals(listOf(1L, 2L, 3L, 4L), snapshot.eventSeqs)
        assertEquals(listOf(3L, 4L), repository.replayPage(listOf(3L, 4L)).map { it.seq })

        repository.acknowledge("mac", seq = 4, highestAuthorized = 4)
        assertThrows(IllegalStateException::class.java) {
            kotlinx.coroutines.runBlocking { repository.replayPage(listOf(1L, 2L)) }
        }
    }

    private fun snapshot(key: String, text: String) = NotificationSnapshot(
        key = key,
        postedAt = 1_000,
        userId = 0,
        packageName = "example.app",
        appLabel = "Example",
        category = "msg",
        content = NotificationContent(text = text, isClearable = true, isGroupSummary = false),
        dnd = DndDescriptor("all", suppressed = false),
        ongoing = false,
    )
}
