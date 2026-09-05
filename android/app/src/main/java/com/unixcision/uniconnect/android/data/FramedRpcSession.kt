package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.MachineFailure

import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.selects.onTimeout
import kotlinx.coroutines.suspendCancellableCoroutine
import org.json.JSONObject

/** One reader, serialized writes and bounded events. A lost delta invalidates the whole connection. */
class FramedRpcSession(private val socket: Socket, private val scope: CoroutineScope) : AutoCloseable {
    private val closed = AtomicBoolean(false)
    private val pending = ConcurrentHashMap<String, CompletableDeferred<RpcEnvelope>>()
    private val events = Channel<RpcEnvelope>(64)
    private val bufferedBytes = AtomicInteger()
    private val writeLock = Mutex()
    private val output = DataOutputStream(socket.getOutputStream())
    private val reader = scope.launch(Dispatchers.IO) {
        try {
            val input = DataInputStream(socket.getInputStream())
            var ordinal = 0L
            while (!closed.get()) {
                val length = input.readInt()
                if (length !in 1..FramedRpcClient.MAX_FRAME_BYTES) throw MachineFailure.ProtocolMismatch()
                val bytes = ByteArray(length)
                input.readFully(bytes)
                val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
                val message = JSONObject(text)
                val envelope = RpcEnvelope(message, ++ordinal, length)
                if (message.optString("kind") == "event") {
                    if (bufferedBytes.addAndGet(length) > FramedRpcClient.MAX_FRAME_BYTES || !events.trySend(envelope).isSuccess) {
                        throw EventBufferOverflow()
                    }
                } else {
                    val completion = pending.remove(message.getString("id")) ?: throw MachineFailure.ProtocolMismatch()
                    completion.complete(envelope)
                }
            }
        } catch (failure: Exception) {
            fail(if (failure is org.json.JSONException || failure is java.nio.charset.CharacterCodingException) MachineFailure.ProtocolMismatch() else failure)
        } finally {
            fail(MachineFailure.Transport())
        }
    }

    suspend fun call(method: String, params: JSONObject): RpcEnvelope {
        check(!closed.get())
        require(pending.size < 16)
        val id = UUID.randomUUID().toString()
        val completion = CompletableDeferred<RpcEnvelope>()
        pending[id] = completion
        try {
            return transportDeadline(12_000) {
                val bytes = JSONObject().put("id", id).put("method", method).put("params", params)
                    .toString().toByteArray(Charsets.UTF_8)
                require(bytes.size in 1..FramedRpcClient.MAX_FRAME_BYTES)
                write(bytes)
                val response = completion.await()
                if (!response.value.optBoolean("ok", false)) {
                    throw MachineFailure.Rejected(response.value.optJSONObject("error")?.optString("code").orEmpty())
                }
                response
            }
        } catch (failure: Exception) {
            // In particular, never leave an uncertain timed-out input alive for another consumer to retry.
            fail(failure)
            throw failure
        } finally {
            pending.remove(id)
        }
    }

    private suspend fun write(bytes: ByteArray) = suspendCancellableCoroutine<Unit> { continuation ->
        val operation = scope.launch(Dispatchers.IO) {
            try {
                writeLock.withLock {
                    check(!closed.get())
                    output.writeInt(bytes.size)
                    output.write(bytes)
                    output.flush()
                }
                if (continuation.isActive) continuation.resume(Unit)
            } catch (failure: Exception) {
                if (continuation.isActive) continuation.resumeWithException(failure)
            }
        }
        continuation.invokeOnCancellation { close(); operation.cancel() }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    suspend fun nextEventOrHeartbeat(milliseconds: Long): RpcEnvelope? {
        check(!closed.get())
        // Atomic selection does not consume an event when the heartbeat wins the race.
        return select {
            events.onReceive { event -> bufferedBytes.addAndGet(-event.byteCount); event }
            onTimeout(milliseconds) { null }
        }
    }

    private fun fail(failure: Exception) {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket.close() }
        pending.values.forEach { it.completeExceptionally(failure) }
        pending.clear()
        events.close(failure)
    }

    override fun close() {
        fail(MachineFailure.Transport())
        reader.cancel()
    }

    class EventBufferOverflow : Exception()
}
