package dev.eko.transport

import dev.eko.core.Frame
import dev.eko.core.FrameCodec
import dev.eko.core.JSON_FRAME_TYPE
import java.io.Closeable
import java.io.OutputStream
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.serialization.json.JsonObject

internal class OutboundActor(
    scope: CoroutineScope,
    private val output: OutputStream,
    val highestAuthorized: AtomicLong = AtomicLong(0),
) : Closeable {
    private val commands = Channel<Command>(capacity = 64)
    private val worker: Job = scope.launch { consume() }

    suspend fun send(message: JsonObject, authorizedThrough: Long? = null) {
        val complete = CompletableDeferred<Unit>()
        commands.send(Command(listOf(message), authorizedThrough, complete))
        complete.await()
    }

    suspend fun sendBatch(messages: List<JsonObject>, authorizedThrough: Long? = null) {
        val complete = CompletableDeferred<Unit>()
        commands.send(Command(messages, authorizedThrough, complete))
        complete.await()
    }

    private suspend fun consume() {
        for (command in commands) {
            try {
                command.authorizedThrough?.let { authorized ->
                    highestAuthorized.updateAndGet { current -> maxOf(current, authorized) }
                }
                command.messages.forEach { message ->
                    FrameCodec.write(output, Frame(JSON_FRAME_TYPE, message.toString().encodeToByteArray()))
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
        val messages: List<JsonObject>,
        val authorizedThrough: Long?,
        val complete: CompletableDeferred<Unit>,
    )
}
