package dev.eko.capture

import android.content.Context
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

data class CaptureHealth(
    val listenerConnected: Boolean = false,
    val lastTransition: String = "never",
    val lastCallbackWall: Long = 0,
    val lastCommitWall: Long = 0,
    val queueDepth: Int = 0,
    val overflowCount: Long = 0,
    val redactionDetected: Boolean = false,
    val lastInterruptionFilter: Int = 0,
    val commitFailures: Long = 0,
    val reconciliationFailures: Long = 0,
    val extractionFailures: Long = 0,
)

class CaptureDiagnostics private constructor(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)
    private val mutable = MutableStateFlow(
        CaptureHealth(
            listenerConnected = false,
            lastTransition = preferences.getString("transition", "never") ?: "never",
            lastCallbackWall = preferences.getLong("callback", 0),
            lastCommitWall = preferences.getLong("commit", 0),
            overflowCount = preferences.getLong("overflow", 0),
            redactionDetected = preferences.getBoolean("redaction", false),
            lastInterruptionFilter = preferences.getInt("filter", 0),
            commitFailures = preferences.getLong("commit_failures", 0),
            reconciliationFailures = preferences.getLong("reconciliation_failures", 0),
            extractionFailures = preferences.getLong("extraction_failures", 0),
        ),
    )
    val state: StateFlow<CaptureHealth> = mutable.asStateFlow()

    fun connected(value: Boolean) = update { it.copy(listenerConnected = value, lastTransition = if (value) "connected" else "disconnected") }
        .also { preferences.edit().putString("transition", if (value) "connected" else "disconnected").commit() }

    fun callback() {
        val now = System.currentTimeMillis()
        update { it.copy(lastCallbackWall = now) }
        preferences.edit().putLong("callback", now).apply()
    }

    fun committed() {
        val now = System.currentTimeMillis()
        update { it.copy(lastCommitWall = now) }
        preferences.edit().putLong("commit", now).apply()
    }

    fun queueDepth(depth: Int) = update { it.copy(queueDepth = depth.coerceAtLeast(0)) }

    fun overflow() {
        val count = state.value.overflowCount + 1
        update { it.copy(overflowCount = count) }
        preferences.edit().putLong("overflow", count).commit()
    }

    fun redactionDetected() {
        update { it.copy(redactionDetected = true) }
        preferences.edit().putBoolean("redaction", true).commit()
    }

    fun commitFailure(kind: String) {
        val count = state.value.commitFailures + 1
        update { it.copy(commitFailures = count, lastTransition = "commit_failure:$kind") }
        preferences.edit().putLong("commit_failures", count).commit()
    }

    fun reconciliationFailed() {
        val count = state.value.reconciliationFailures + 1
        update { it.copy(reconciliationFailures = count) }
        preferences.edit().putLong("reconciliation_failures", count).commit()
    }

    fun extractionFailure(kind: String) {
        val count = state.value.extractionFailures + 1
        update { it.copy(extractionFailures = count, lastTransition = "extraction_failure:$kind") }
        preferences.edit().putLong("extraction_failures", count).commit()
    }

    fun interruptionFilter(filter: Int) {
        update { it.copy(lastInterruptionFilter = filter) }
        preferences.edit().putInt("filter", filter).apply()
    }

    fun disconnectedAt(): Long = preferences.getLong("disconnected_at", 0)

    fun markDisconnectedAt(wall: Long) {
        preferences.edit().putLong("disconnected_at", wall).commit()
    }

    fun clearDisconnectedAt() {
        preferences.edit().remove("disconnected_at").commit()
    }

    private inline fun update(transform: (CaptureHealth) -> CaptureHealth) {
        mutable.value = transform(mutable.value)
    }

    companion object {
        private const val NAME = "eko-capture-health"
        private val reference = AtomicReference<CaptureDiagnostics?>()

        fun get(context: Context): CaptureDiagnostics = reference.get() ?: synchronized(this) {
            reference.get() ?: CaptureDiagnostics(context).also(reference::set)
        }
    }
}
