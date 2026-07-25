package dev.eko.capture

import dev.eko.outbox.CaptureCommit
import dev.eko.outbox.EventStoreProvider
import dev.eko.outbox.EventStoreResetLock
import dev.eko.outbox.NotificationSnapshot
import java.io.Closeable
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch

internal interface CaptureSink {
    suspend fun posted(snapshot: NotificationSnapshot, reconciled: Boolean): CaptureCommit
    suspend fun removed(key: String, reason: Int, reconciled: Boolean): CaptureCommit
    suspend fun reconcile(visible: List<NotificationSnapshot>): List<CaptureCommit.Committed>
    suspend fun gap(evidence: String, startWall: Long?, endWall: Long?): CaptureCommit.Committed
}

internal class RoomCaptureSink(private val context: android.content.Context) : CaptureSink {
    private val commitsSinceRetention = AtomicInteger(0)
    private fun repository() = EventStoreProvider.repository(context)
    override suspend fun posted(snapshot: NotificationSnapshot, reconciled: Boolean): CaptureCommit =
        EventStoreResetLock.withResetLock {
            repository().commitNotification(snapshot, reconciled)
        }.also { maintainRetention(if (it is CaptureCommit.Committed) 1 else 0) }
    override suspend fun removed(key: String, reason: Int, reconciled: Boolean): CaptureCommit =
        EventStoreResetLock.withResetLock {
            repository().commitRemoval(key, reason, reconciled)
        }.also { maintainRetention(if (it is CaptureCommit.Committed) 1 else 0) }
    override suspend fun reconcile(visible: List<NotificationSnapshot>): List<CaptureCommit.Committed> =
        EventStoreResetLock.withResetLock {
            repository().reconcile(visible)
        }.also { maintainRetention(it.size) }
    override suspend fun gap(evidence: String, startWall: Long?, endWall: Long?): CaptureCommit.Committed =
        EventStoreResetLock.withResetLock {
            repository().commitCaptureGap(evidence, startWall, endWall)
        }.also { maintainRetention(1) }

    private suspend fun maintainRetention(committedCount: Int) {
        if (committedCount == 0 || commitsSinceRetention.addAndGet(committedCount) < RETENTION_BATCH) return
        commitsSinceRetention.set(0)
        val repository = repository()
        repository.pairingRows().forEach { repository.applyRetention(it.pairingId) }
        repository.pruneUnneededRows()
    }

    private companion object {
        const val RETENTION_BATCH = 32
    }
}

internal sealed interface CaptureCommand {
    val ordinal: Long
    data class Posted(override val ordinal: Long, val snapshot: NotificationSnapshot, val reconciled: Boolean = false) : CaptureCommand
    data class Removed(override val ordinal: Long, val key: String, val reason: Int, val reconciled: Boolean = false) : CaptureCommand
    data class Reconcile(
        override val ordinal: Long,
        val visible: List<NotificationSnapshot>,
        val onCommitted: () -> Unit,
    ) : CaptureCommand
    data class Gap(override val ordinal: Long, val evidence: String, val startWall: Long?, val endWall: Long?) : CaptureCommand
}

class SerializedNotificationWriter internal constructor(
    scope: CoroutineScope,
    private val sink: CaptureSink,
    private val diagnostics: CaptureDiagnostics,
    capacity: Int = DEFAULT_CAPACITY,
) : Closeable {
    private val channel = Channel<CaptureCommand>(capacity)
    private val acceptedOrdinal = AtomicLong(0)
    private val queueDepth = AtomicInteger(0)
    private val overflowLock = Any()
    private var overflow: OverflowEvidence? = null
    private val worker: Job = scope.launch { consume() }

    fun post(snapshot: NotificationSnapshot, reconciled: Boolean = false): Boolean =
        offer { CaptureCommand.Posted(it, snapshot, reconciled) }

    fun remove(key: String, reason: Int, reconciled: Boolean = false): Boolean =
        offer { CaptureCommand.Removed(it, key, reason, reconciled) }

    fun reconcile(visible: List<NotificationSnapshot>, onCommitted: () -> Unit = {}): Boolean =
        offer { CaptureCommand.Reconcile(it, visible, onCommitted) }

    fun gap(evidence: String, startWall: Long?, endWall: Long?): Boolean =
        offer { CaptureCommand.Gap(it, evidence, startWall, endWall) }

    private fun offer(factory: (Long) -> CaptureCommand): Boolean {
        while (true) {
            val current = acceptedOrdinal.get()
            val command = factory(current + 1)
            val result = channel.trySend(command)
            if (result.isSuccess) {
                acceptedOrdinal.compareAndSet(current, current + 1)
                diagnostics.queueDepth(queueDepth.incrementAndGet())
                return true
            }
            recordOverflow(current)
            return false
        }
    }

    private fun recordOverflow(barrierOrdinal: Long) {
        val now = System.currentTimeMillis()
        synchronized(overflowLock) {
            overflow = overflow?.copy(endWall = now, count = overflow!!.count + 1)
                ?: OverflowEvidence(barrierOrdinal, now, now, 1)
        }
        diagnostics.overflow()
    }

    private suspend fun consume() {
        var processedOrdinal = 0L
        while (true) {
            flushOverflowIfReady(processedOrdinal)
            val command = channel.receiveCatching().getOrNull() ?: break
            queueDepth.decrementAndGet().also(diagnostics::queueDepth)
            val committed = runSinkCommand(command)
            if (committed) {
                processedOrdinal = command.ordinal
                diagnostics.committed()
            } else {
                processedOrdinal = command.ordinal
                recordOverflow(command.ordinal)
            }
            flushOverflowIfReady(processedOrdinal)
        }
    }

    private suspend fun runSinkCommand(command: CaptureCommand): Boolean = try {
        when (command) {
            is CaptureCommand.Posted -> sink.posted(command.snapshot, command.reconciled)
            is CaptureCommand.Removed -> sink.removed(command.key, command.reason, command.reconciled)
            is CaptureCommand.Reconcile -> {
                sink.reconcile(command.visible)
                command.onCommitted()
            }
            is CaptureCommand.Gap -> sink.gap(command.evidence, command.startWall, command.endWall)
        }
        true
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (error: Throwable) {
        diagnostics.commitFailure(error.javaClass.simpleName)
        false
    }

    private suspend fun flushOverflowIfReady(processedOrdinal: Long) {
        val evidence = synchronized(overflowLock) {
            overflow?.takeIf { processedOrdinal >= it.barrierOrdinal }
        } ?: return
        try {
            sink.gap("writer_overflow", evidence.startWall, evidence.endWall)
            synchronized(overflowLock) {
                if (overflow === evidence) overflow = null
            }
            diagnostics.committed()
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (error: Throwable) {
            diagnostics.commitFailure(error.javaClass.simpleName)
        }
    }

    /**
     * Graceful close: stop accepting commands, but let the consumer drain what is
     * already queued.
     *
     * This is only half the contract. `channel.close()` tells `consume()` to finish
     * the buffer and exit, but it returns immediately — so a caller that cancels the
     * owning scope on the next line destroys the consumer mid-drain and silently
     * discards every queued commit. Callers that are tearing the writer down must use
     * [closeAndDrain].
     */
    override fun close() {
        channel.close()
    }

    /**
     * Closes the channel and waits for the consumer to finish the buffered commands.
     *
     * Every queued command represents a notification `onNotificationPosted` has already
     * accepted from the system, so dropping one breaks "persist durably at post time,
     * before any send attempt" — and does so invisibly, because the disconnect-interval
     * gap the listener records covers a window *after* those notifications were posted.
     * Callers should bound this with `withTimeout` and treat a timeout as evidence of a
     * capture gap.
     */
    suspend fun closeAndDrain() {
        channel.close()
        worker.join()
    }

    /** Commands accepted but not yet handed to the sink. Zero after a completed drain. */
    val pending: Int get() = queueDepth.get()

    private data class OverflowEvidence(
        val barrierOrdinal: Long,
        val startWall: Long,
        val endWall: Long,
        val count: Long,
    )

    companion object {
        const val DEFAULT_CAPACITY = 256

        fun create(context: android.content.Context, scope: CoroutineScope): SerializedNotificationWriter =
            SerializedNotificationWriter(scope, RoomCaptureSink(context.applicationContext), CaptureDiagnostics.get(context))
    }
}
