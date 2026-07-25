package dev.eko.outbox

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class DurabilityInstrumentedTest {
    @Test
    fun fileStoreUsesWalAndFullSynchronous() = runBlocking {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.deleteDatabase(EventStoreProvider.DATABASE_NAME)
        val repository = EventStoreProvider.repository(context)
        repository.initialize("instrumented-generation")
        val database = EventStoreProvider.database(context).openHelper.writableDatabase

        val journal = database.query("PRAGMA journal_mode").use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getString(0).lowercase()
        }
        val synchronous = database.query("PRAGMA synchronous").use { cursor ->
            assertTrue(cursor.moveToFirst())
            cursor.getInt(0)
        }

        assertEquals("wal", journal)
        assertEquals(2, synchronous)
        assertTrue(StoreHealth.durability.value is StoreDurability.Healthy)
    }
}
