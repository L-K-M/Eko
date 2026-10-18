package dev.eko.outbox

import android.database.sqlite.SQLiteDatabaseCorruptException

object EventStoreFailurePolicy {
    fun requiresReset(error: Throwable): Boolean = isVerifiedCorruption(error)

    fun isVerifiedCorruption(error: Throwable): Boolean =
        generateSequence(error, Throwable::cause).any { it is SQLiteDatabaseCorruptException }
}
