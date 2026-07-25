package dev.eko.capture

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import dev.eko.core.DndDescriptor
import dev.eko.core.EventKind
import dev.eko.core.NotificationContent
import dev.eko.outbox.CaptureCommit
import dev.eko.outbox.NotificationSnapshot
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SerializedNotificationWriterTest {
    @Test
    fun `bounded writer preserves accepted order and records overflow after its barrier`() = runTest {
        val gate = CompletableDeferred<Unit>()
        val sink = RecordingSink(gate)
        val context = ApplicationProvider.getApplicationContext<Context>()
        val writer = SerializedNotificationWriter(
            scope = this,
            sink = sink,
            diagnostics = CaptureDiagnostics.get(context),
            capacity = 1,
        )

        assertTrue(writer.post(snapshot("one")))
        runCurrent()
        assertTrue(writer.post(snapshot("two")))
        assertFalse(writer.post(snapshot("overflow")))
        gate.complete(Unit)
        runCurrent()
        writer.close()
        advanceUntilIdle()

        assertEquals(listOf("posted:one", "posted:two", "gap:writer_overflow"), sink.calls)
    }

    @Test
    fun `writer survives a sink failure and still emits overflow evidence`() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val sink = RecordingSink(null, failPostedKeys = setOf("bad"))
        val writer = SerializedNotificationWriter(
            scope = this,
            sink = sink,
            diagnostics = CaptureDiagnostics.get(context),
            capacity = 8,
        )

        assertTrue(writer.post(snapshot("bad")))
        assertTrue(writer.post(snapshot("good")))
        writer.close()
        advanceUntilIdle()

        assertEquals(listOf("gap:writer_overflow", "posted:good"), sink.calls)
        assertTrue(CaptureDiagnostics.get(context).state.value.commitFailures > 0)
    }

    @Test
    fun `failed reconcile never reports reconciliation committed`() = runTest {
        val context = ApplicationProvider.getApplicationContext<Context>()
        val sink = RecordingSink(null, failReconcile = true)
        val writer = SerializedNotificationWriter(
            scope = this,
            sink = sink,
            diagnostics = CaptureDiagnostics.get(context),
            capacity = 8,
        )
        var committed = false

        assertTrue(writer.reconcile(emptyList()) { committed = true })
        assertTrue(writer.post(snapshot("after")))
        writer.close()
        advanceUntilIdle()

        assertFalse(committed)
        assertEquals(listOf("posted:after"), sink.calls.filterNot { it.startsWith("gap:") })
    }

    private fun snapshot(key: String) = NotificationSnapshot(
        key = key,
        postedAt = 1,
        userId = 0,
        packageName = "example.app",
        appLabel = "Example",
        category = "msg",
        content = NotificationContent(text = key, isClearable = true, isGroupSummary = false),
        dnd = DndDescriptor("all", false),
        ongoing = false,
    )

    private class RecordingSink(
        private val firstGate: CompletableDeferred<Unit>?,
        private val failPostedKeys: Set<String> = emptySet(),
        private val failReconcile: Boolean = false,
    ) : CaptureSink {
        val calls = mutableListOf<String>()

        override suspend fun posted(snapshot: NotificationSnapshot, reconciled: Boolean): CaptureCommit {
            firstGate?.await()
            if (snapshot.key in failPostedKeys) throw IllegalStateException("simulated store failure")
            calls += "posted:${snapshot.key}"
            return CaptureCommit.Committed(calls.size.toLong(), EventKind.POSTED)
        }

        override suspend fun removed(key: String, reason: Int, reconciled: Boolean) =
            CaptureCommit.Committed(calls.size.toLong(), EventKind.REMOVED)

        override suspend fun reconcile(visible: List<NotificationSnapshot>): List<CaptureCommit.Committed> {
            if (failReconcile) throw IllegalStateException("simulated reconcile failure")
            return emptyList()
        }

        override suspend fun gap(evidence: String, startWall: Long?, endWall: Long?): CaptureCommit.Committed {
            calls += "gap:$evidence"
            return CaptureCommit.Committed(calls.size.toLong(), EventKind.CAPTURE_GAP)
        }
    }
}
