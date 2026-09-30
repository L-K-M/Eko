package dev.eko.outbox

import android.database.sqlite.SQLiteCantOpenDatabaseException
import android.database.sqlite.SQLiteDatabaseCorruptException
import android.database.sqlite.SQLiteDatabaseLockedException
import android.database.sqlite.SQLiteDiskIOException
import android.database.sqlite.SQLiteException
import android.database.sqlite.SQLiteFullException
import java.io.IOException
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class EventStoreFailurePolicyTest {
    @Test
    fun `verified corruption requires a journaled reset`() {
        assertTrue(EventStoreFailurePolicy.requiresReset(SQLiteDatabaseCorruptException("database disk image is malformed")))
        assertTrue(
            EventStoreFailurePolicy.requiresReset(
                IllegalStateException("Room open failed", SQLiteDatabaseCorruptException("malformed")),
            ),
        )
    }

    @Test
    fun `transient open and storage failures never require a reset`() {
        val transient = listOf(
            SQLiteCantOpenDatabaseException("unable to open database file"),
            SQLiteDatabaseLockedException("database is locked"),
            SQLiteFullException("database or disk is full"),
            SQLiteDiskIOException("disk I/O error"),
            SQLiteException("generic sqlite failure"),
            IllegalStateException("Required WAL/FULL, effective journal=memory synchronous=1"),
            IOException("storage not mounted yet"),
        )
        transient.forEach { error ->
            assertFalse("${error.javaClass.simpleName} must not delete the store", EventStoreFailurePolicy.requiresReset(error))
        }
    }
}
