package dev.eko.outbox

import android.content.Context
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import androidx.sqlite.db.SupportSQLiteDatabase
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

@Database(
    entities = [
        MetadataEntity::class,
        OutboxEventEntity::class,
        PairingCursorEntity::class,
        GapSpanEntity::class,
        ActiveNotificationEntity::class,
        AppRuleEntity::class,
        SeenAppEntity::class,
    ],
    version = 1,
    exportSchema = true,
)
abstract class EventDatabase : RoomDatabase() {
    abstract fun metadata(): MetadataDao
    abstract fun outbox(): OutboxDao
    abstract fun pairings(): PairingCursorDao
    abstract fun gaps(): GapSpanDao
    abstract fun active(): ActiveNotificationDao
    abstract fun appRules(): AppRuleDao
}

sealed interface StoreDurability {
    data object Opening : StoreDurability
    data class Healthy(val journalMode: String, val synchronous: Int) : StoreDurability
    data class Unhealthy(val reason: String) : StoreDurability
}

object StoreHealth {
    private val mutable = MutableStateFlow<StoreDurability>(StoreDurability.Opening)
    val durability: StateFlow<StoreDurability> = mutable

    internal fun update(value: StoreDurability) {
        mutable.value = value
    }
}

object EventStoreProvider {
    const val DATABASE_NAME = "eko-events.db"
    private val databaseReference = AtomicReference<EventDatabase?>()

    fun database(context: Context): EventDatabase {
        databaseReference.get()?.let { return it }
        synchronized(this) {
            databaseReference.get()?.let { return it }
            val database = build(context.applicationContext)
            databaseReference.set(database)
            return database
        }
    }

    fun repository(context: Context): EventRepository = EventRepository(database(context), BootAwareClock(context))

    internal fun closeAndDelete(context: Context) {
        synchronized(this) {
            databaseReference.getAndSet(null)?.close()
            check(context.applicationContext.deleteDatabase(DATABASE_NAME) ||
                !context.applicationContext.getDatabasePath(DATABASE_NAME).exists()) {
                "Unable to replace the event database"
            }
            StoreHealth.update(StoreDurability.Opening)
        }
    }

    private fun build(context: Context): EventDatabase = Room.databaseBuilder(
        context,
        EventDatabase::class.java,
        DATABASE_NAME,
    )
        .setJournalMode(RoomDatabase.JournalMode.WRITE_AHEAD_LOGGING)
        .addCallback(DurabilityCallback())
        .build()
}

private class DurabilityCallback : RoomDatabase.Callback() {
    override fun onOpen(db: SupportSQLiteDatabase) {
        super.onOpen(db)
        try {
            db.execSQL("PRAGMA synchronous=FULL")
            val journal = db.query("PRAGMA journal_mode").use { cursor ->
                check(cursor.moveToFirst())
                cursor.getString(0).lowercase()
            }
            val synchronous = db.query("PRAGMA synchronous").use { cursor ->
                check(cursor.moveToFirst())
                cursor.getInt(0)
            }
            if (journal != "wal" || synchronous != 2) {
                val reason = "Required WAL/FULL, effective journal=$journal synchronous=$synchronous"
                StoreHealth.update(StoreDurability.Unhealthy(reason))
                throw IllegalStateException(reason)
            }
            StoreHealth.update(StoreDurability.Healthy(journal, synchronous))
        } catch (error: Throwable) {
            if (StoreHealth.durability.value !is StoreDurability.Unhealthy) {
                StoreHealth.update(StoreDurability.Unhealthy(error.message ?: error.javaClass.simpleName))
            }
            throw error
        }
    }
}
