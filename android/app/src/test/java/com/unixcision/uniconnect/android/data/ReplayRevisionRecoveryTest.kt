package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.*
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import org.json.JSONObject
import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Test

class ReplayRevisionRecoveryTest {
    private val target = TerminalTarget("workspace-a", "surface-a")
    private val machine = Machine("machine-a", "Equipo", requireNotNull(MachineEndpoint.parse("100.64.0.1", "58465")))

    @Test fun staleFullEventCannotCancelReplayRequiredByNewerResizingDelta() = runScenario(staleReplay = false)

    @Test fun staleReplayCannotCompleteRecoveryBelowTheMissingRevision() = runScenario(staleReplay = true)

    private fun runScenario(staleReplay: Boolean) = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val host = scope.async {
                val subscription = pair.read()
                assertEquals("mobile.events.subscribe", subscription.getString("method"))
                pair.reply(subscription, JSONObject().put("stream_id", subscription.getJSONObject("params").getString("stream_id")))
                val list = pair.read()
                assertEquals("mobile.workspace.list", list.getString("method"))
                pair.reply(list, JSONObject("""{"workspaces":[]}"""))
                val initialReplay = pair.read()
                assertEquals("mobile.terminal.replay", initialReplay.getString("method"))
                // Queue the complete batch before resolving replay so the reader cannot split the repro.
                pair.event(grid(revision = 11, columns = 100, full = false))
                if (!staleReplay) pair.event(grid(revision = 9, columns = 80, full = true))
                pair.reply(initialReplay, replay(grid(revision = 10, columns = 80, full = true)))
                val recovery = pair.read()
                assertEquals("mobile.terminal.replay", recovery.getString("method"))
                if (staleReplay) {
                    pair.event(grid(revision = 10, columns = 80, full = true))
                    pair.event(grid(revision = 11, columns = 100, full = true))
                    pair.reply(recovery, replay(grid(revision = 9, columns = 80, full = true)))
                } else {
                    pair.reply(recovery, replay(grid(revision = 11, columns = 100, full = true)))
                }
                assertEquals(-1, pair.remote.getInputStream().read())
            }
            val screens = withTimeout(4_000) {
                FramedRpcSession(pair.local, scope).use { session ->
                    NativeMachineClient(FramedRpcClient(scope)).observeSession(session, machine, target)
                        .filterIsInstance<MachineUpdate.Terminal>().take(2).toList()
                }
            }
            assertEquals(listOf(10uL, 11uL), screens.map { it.snapshot.revision })
            assertEquals(listOf(80, 100), screens.map { it.snapshot.columns })
            withTimeout(2_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    private fun grid(revision: Int, columns: Int, full: Boolean) = JSONObject()
        .put("format", "cmux.render-grid.v1").put("surface_id", target.windowID)
        .put("columns", columns).put("rows", 1).put("full", full).put("revision", revision)
        .put("row_spans", JSONArray())
    private fun replay(grid: JSONObject) = JSONObject().put("workspace_id", target.workspaceID)
        .put("surface_id", target.windowID).put("is_ready", true).put("render_grid", grid)

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
        fun reply(request: JSONObject, result: JSONObject) = write(JSONObject().put("id", request.getString("id")).put("ok", true).put("result", result))
        fun event(grid: JSONObject) = write(JSONObject().put("kind", "event").put("topic", "terminal.render_grid").put("payload", grid))
        private fun write(value: JSONObject) {
            val bytes = value.toString().toByteArray(Charsets.UTF_8)
            DataOutputStream(remote.getOutputStream()).apply { writeInt(bytes.size); write(bytes); flush() }
        }
        override fun close() { local.close(); remote.close() }
    }
}
