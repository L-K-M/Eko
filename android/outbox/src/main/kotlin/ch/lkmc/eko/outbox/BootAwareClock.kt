package dev.eko.outbox

import android.content.Context
import android.os.SystemClock
import android.provider.Settings

data class StoreTimestamp(
    val wall: Long,
    val elapsed: Long,
    val bootId: String,
)

class BootAwareClock(context: Context) {
    private val appContext = context.applicationContext
    private val preferences = appContext.getSharedPreferences("eko-clock", Context.MODE_PRIVATE)

    fun now(): StoreTimestamp {
        val observedWall = System.currentTimeMillis()
        val previousWall = preferences.getLong(KEY_LAST_WALL, 0)
        val clampedWall = maxOf(observedWall, previousWall)
        if (clampedWall != previousWall) preferences.edit().putLong(KEY_LAST_WALL, clampedWall).commit()
        return StoreTimestamp(clampedWall, SystemClock.elapsedRealtime(), currentBootId())
    }

    fun isExpired(event: OutboxEventEntity, ageMillis: Long, now: StoreTimestamp = now()): Boolean {
        if (ageMillis <= 0) return true
        return if (event.createdBoot == now.bootId && now.elapsed >= event.createdElapsed) {
            now.elapsed - event.createdElapsed >= ageMillis
        } else {
            now.wall >= event.createdWall && now.wall - event.createdWall >= ageMillis
        }
    }

    private fun currentBootId(): String {
        val count = Settings.Global.getInt(appContext.contentResolver, Settings.Global.BOOT_COUNT, -1)
        return if (count >= 0) "boot-$count" else "boot-${android.os.Build.TIME}"
    }

    private companion object {
        const val KEY_LAST_WALL = "last_wall"
    }
}
