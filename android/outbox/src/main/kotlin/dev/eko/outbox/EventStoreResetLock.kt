package dev.eko.outbox

import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

object EventStoreResetLock {
    private val mutex = Mutex()

    suspend fun <T> withResetLock(block: suspend () -> T): T = mutex.withLock { block() }
}
