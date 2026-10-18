package dev.eko.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class BackoffTest {
    @Test
    fun `full jitter grows exponentially and caps at sixty seconds`() {
        val bounds = mutableListOf<Long>()
        val backoff = FullJitterBackoff(jitter = JitterSource { bound ->
            bounds += bound
            bound - 1
        })

        val delays = List(10) { backoff.nextDelayMillis() }

        assertEquals(listOf(1_000L, 2_000L, 4_000L, 8_000L, 16_000L, 32_000L), delays.take(6))
        assertTrue(delays.drop(6).all { it == 60_000L })
        assertEquals(1_001L, bounds.first())
    }

    @Test
    fun `attempt resets only after a stable connection`() {
        val backoff = FullJitterBackoff(jitter = JitterSource { 0 })
        backoff.nextDelayMillis()
        backoff.recordStableConnection(59_999)
        assertEquals(1, backoff.attempt)
        backoff.recordStableConnection(60_000)
        assertEquals(0, backoff.attempt)
    }
}
