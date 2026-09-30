package dev.eko.capture

import android.app.Notification
import android.service.notification.StatusBarNotification
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class ReconciliationSnapshotTest {
    @Test
    fun `activeNotifications failure is never an authoritative empty reconciliation`() {
        val result = collectReconciliationSnapshots(
            activeNotifications = { throw SecurityException("listener access not granted") },
            extract = { throw AssertionError("extraction must not run when enumeration failed") },
            onWriterOverflow = { },
        )

        assertNull(result)
    }

    @Test
    fun `a genuinely empty active set reconciles to an empty snapshot list`() {
        val result = collectReconciliationSnapshots(
            activeNotifications = { emptyArray<StatusBarNotification>() },
            extract = { null },
            onWriterOverflow = { },
        )

        assertEquals(emptyList<dev.eko.outbox.NotificationSnapshot>(), result)
    }

    @Test
    fun `writer overflow extractions surface evidence instead of a snapshot`() {
        var overflows = 0
        val sbn = StatusBarNotification(
            "example.app",
            "example.app",
            1,
            null,
            10_000,
            0,
            0,
            Notification(),
            android.os.Process.myUserHandle(),
            1L,
        )

        val result = collectReconciliationSnapshots(
            activeNotifications = { arrayOf(sbn) },
            extract = { ExtractedNotification(snapshot = null, redacted = false, writerOverflow = true) },
            onWriterOverflow = { overflows += 1 },
        )

        assertEquals(1, overflows)
        assertEquals(emptyList<dev.eko.outbox.NotificationSnapshot>(), result)
    }
}
