package dev.eko.core

import kotlin.math.min
import kotlin.random.Random

fun interface JitterSource {
    fun nextLong(untilExclusive: Long): Long
}

class FullJitterBackoff(
    private val baseMillis: Long = 1_000,
    private val capMillis: Long = 60_000,
    private val jitter: JitterSource = JitterSource { bound -> Random.Default.nextLong(bound) },
) {
    var attempt: Int = 0
        private set

    fun nextDelayMillis(): Long {
        val shift = attempt.coerceAtMost(30)
        val exponential = if (baseMillis > Long.MAX_VALUE.shr(shift)) Long.MAX_VALUE else baseMillis shl shift
        val ceiling = min(capMillis, exponential).coerceAtLeast(1)
        attempt = (attempt + 1).coerceAtMost(31)
        return jitter.nextLong(ceiling + 1).coerceIn(0, ceiling)
    }

    fun recordStableConnection(durationMillis: Long) {
        if (durationMillis >= 60_000) reset()
    }

    fun reset() {
        attempt = 0
    }
}
