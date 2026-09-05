package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.TerminalTarget
import kotlinx.coroutines.*
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

class ColdTerminalSubscriptionTest {
    private val target = TerminalTarget("workspace-a", "surface-a")

    @Test fun firstFullEventCompletesTheOriginalReplayWithoutPolling() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val host = scope.async {
                val request = pair.read()
                assertEquals("mobile.terminal.replay", request.getString("method"))
                pair.write(JSONObject().put("id", request.getString("id")).put("ok", true).put("result", pending()))
                pair.write(event("another-surface", "ignorar"))
                pair.write(event(target.windowID, "lista"))
                // The client closes after receiving the event: no second replay, create, attach or input RPC.
                assertEquals(-1, pair.remote.getInputStream().read())
            }
            val snapshot = FramedRpcSession(pair.local, scope).use { session ->
                NativeMachineClient(FramedRpcClient(scope)).requestReplay(session, target).snapshot
            }
            assertEquals("lista", snapshot.spans.single().text)
            withTimeout(2_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    @Test fun cancellationDuringColdWaitClosesOwnedSessionWithoutAnotherRequest() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        val pendingSent = CompletableDeferred<Unit>()
        try {
            val host = scope.async {
                val request = pair.read()
                pair.write(JSONObject().put("id", request.getString("id")).put("ok", true).put("result", pending()))
                pendingSent.complete(Unit)
                assertEquals(-1, pair.remote.getInputStream().read())
            }
            val waiting = launch {
                FramedRpcSession(pair.local, scope).use { session ->
                    NativeMachineClient(FramedRpcClient(scope)).requestReplay(session, target)
                }
            }
            withTimeout(2_000) { pendingSent.await() }
            waiting.cancelAndJoin()
            assertTrue(waiting.isCancelled)
            withTimeout(2_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    private fun pending() = JSONObject().put("workspace_id", target.workspaceID).put("surface_id", target.windowID).put("is_ready", false).put("seq", 0)
    private fun event(surfaceID: String, text: String) = JSONObject().put("kind", "event").put("topic", "terminal.render_grid")
        .put("payload", JSONObject("""{"format":"cmux.render-grid.v1","surface_id":"$surfaceID","columns":20,"rows":1,"full":true,"revision":1,"row_spans":[{"row":0,"column":0,"text":"$text","cell_width":${text.length}}]}"""))

    private class SocketPair : AutoCloseable {
        val local: Socket
        val remote: Socket
        init {
            ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { listener ->
                local = Socket(InetAddress.getLoopbackAddress(), listener.localPort)
                remote = listener.accept().apply { soTimeout = 3_000 }
            }
        }
        fun read(): JSONObject {
            val input = DataInputStream(remote.getInputStream())
            val bytes = ByteArray(input.readInt().also { require(it in 1..8192) })
            input.readFully(bytes)
            return JSONObject(String(bytes, Charsets.UTF_8))
        }
        fun write(value: JSONObject) {
            val bytes = value.toString().toByteArray(Charsets.UTF_8)
            DataOutputStream(remote.getOutputStream()).apply { writeInt(bytes.size); write(bytes); flush() }
        }
        override fun close() { local.close(); remote.close() }
    }
}
