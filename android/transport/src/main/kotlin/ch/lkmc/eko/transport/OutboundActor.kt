package dev.eko.transport

import dev.eko.core.Frame
import dev.eko.core.FrameCodec
import dev.eko.core.JSON_FRAME_TYPE
import dev.eko.core.ProtocolException
import java.io.Closeable
import java.io.OutputStream
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.JsonObject

internal class OutboundActor(
    scope: CoroutineScope,
    private val output: OutputStream,
    initialAuthorizedThrough: Long = 0,
) : Closeable {
    private val commands = Channel<Command>(capacity = 64)
    private val authorizationBarrier = Mutex()
    private var highestAuthorized = initialAuthorizedThrough

    init {
        require(initialAuthorizedThrough >= 0) { "Initial authorization cannot be negative" }
    }

    private val worker: Job = scope.launch { consume() }

    suspend fun send(message: JsonObject, sequence: Long? = null) {
        enqueue(listOf(OutboundFrame(message, sequence?.let { SequenceCoverage(it, it) })))
    }

    suspend fun sendBatch(messages: List<JsonObject>) {
        enqueue(messages.map(::OutboundFrame))
    }

    suspend fun sendFrames(frames: List<OutboundFrame>) {
        enqueue(frames)
    }

    private suspend fun enqueue(frames: List<OutboundFrame>) {
        val complete = CompletableDeferred<Unit>()
        commands.send(Command(frames, complete))
        complete.await()
    }

    suspend fun authorizedThrough(): Long = authorizationBarrier.withLock { highestAuthorized }

    private suspend fun consume() {
        for (command in commands) {
            try {
                command.frames.forEach { frame ->
                    val coverage = frame.coverage
                    if (coverage == null) {
                        FrameCodec.write(
                            output,
                            Frame(JSON_FRAME_TYPE, frame.message.toString().encodeToByteArray()),
                        )
                    } else {
                        authorizationBarrier.withLock {
                            if (coverage.from != highestAuthorized + 1) {
                                throw ProtocolException(
                                    "Outbound sequence coverage starts at ${coverage.from}; expected ${highestAuthorized + 1}",
                                )
                            }
                            FrameCodec.write(
                                output,
                                Frame(JSON_FRAME_TYPE, frame.message.toString().encodeToByteArray()),
                            )
                            highestAuthorized = coverage.through
                        }
                    }
                }
                command.complete.complete(Unit)
            } catch (error: Throwable) {
                command.complete.completeExceptionally(error)
                commands.close(error)
                break
            }
        }
    }

    override fun close() {
        commands.close()
        worker.cancel()
    }

    private data class Command(
        val frames: List<OutboundFrame>,
        val complete: CompletableDeferred<Unit>,
    )
}

internal data class OutboundFrame(
    val message: JsonObject,
    val coverage: SequenceCoverage? = null,
)

internal data class SequenceCoverage(
    val from: Long,
    val through: Long,
) {
    init {
        require(from >= 1) { "Sequence coverage must start at a positive position" }
        require(through >= from) { "Sequence coverage cannot regress" }
    }
}
