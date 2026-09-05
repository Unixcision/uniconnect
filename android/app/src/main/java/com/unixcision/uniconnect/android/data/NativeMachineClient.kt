package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.*
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray
import org.json.JSONObject

/** The host approves the observed peer IP. This client never sends SSH secrets or creates on attach. */
class NativeMachineClient(private val rpc: FramedRpcClient) : MachineClient {
    private val decoder = TerminalFrameDecoder()

    override fun observe(machine: Machine, terminal: TerminalTarget?): Flow<MachineUpdate> = flow {
        rpc.open(machine.endpoint).use { session ->
            val streamID = UUID.randomUUID().toString()
            val topics = JSONArray().put("workspace.updated")
            if (terminal != null) topics.put("terminal.render_grid")
            val subscribed = session.call("mobile.events.subscribe", JSONObject().put("stream_id", streamID).put("topics", topics))
            require(subscribed.value.getJSONObject("result").getString("stream_id") == streamID)
            emit(MachineUpdate.Workspaces(decodeMachine(machine, session.call("mobile.workspace.list", JSONObject()).value.getJSONObject("result"))))
            var screen: TerminalSnapshot? = null
            var replayOrdinal = 0L
            if (terminal != null) {
                val replay = session.call("mobile.terminal.replay", target(terminal.workspaceID, terminal.windowID))
                screen = decodeReplay(replay.value.getJSONObject("result"), terminal.windowID)
                replayOrdinal = replay.ordinal
                emit(MachineUpdate.Terminal(screen))
            }
            while (true) {
                val event = session.nextEventOrHeartbeat(15_000)
                // A bounded RPC heartbeat detects silent network loss even when the desktop is idle.
                if (event == null || event.value.optString("topic") == "workspace.updated") {
                    emit(MachineUpdate.Workspaces(decodeMachine(machine, session.call("mobile.workspace.list", JSONObject()).value.getJSONObject("result"))))
                    continue
                }
                if (terminal == null || event.value.optString("topic") != "terminal.render_grid") continue
                val payload = event.value.getJSONObject("payload")
                val grid = payload.optJSONObject("render_grid") ?: payload
                if (!grid.optString("surface_id").equals(terminal.windowID, ignoreCase = true)) continue
                val frame = decoder.decode(grid, terminal.windowID)
                // Versioned full events may have been captured after replay but enqueued before its response.
                // Compare visual revisions; only legacy, unversioned frames use the receive-order barrier.
                if (frame.snapshot.revision == null && event.ordinal <= replayOrdinal) continue
                screen = try {
                    frame.applyingTo(screen)
                } catch (_: TerminalFrame.FullReplayRequired) {
                    val replay = session.call("mobile.terminal.replay", target(terminal.workspaceID, terminal.windowID))
                    replayOrdinal = replay.ordinal
                    decodeReplay(replay.value.getJSONObject("result"), terminal.windowID)
                }
                emit(MachineUpdate.Terminal(requireNotNull(screen)))
            }
        }
    }.catch { failure ->
        if (failure is org.json.JSONException || failure is IllegalArgumentException) throw MachineFailure.ProtocolMismatch()
        throw failure
    }.flowOn(Dispatchers.Default)

    override suspend fun inspect(machine: Machine): MachineSnapshot = decodeMachine(machine, call(machine, "mobile.workspace.list", JSONObject()))

    override suspend fun create(machine: Machine, request: ResourceCreation): CreationResult {
        require(request.isValid())
        val params = JSONObject().put("name", request.name)
        request.directory?.let { params.put("directory", it) }
        val method = when (request) {
            is ResourceCreation.Workspace -> {
                params.put("kind", if (request.sourceWorkspaceID == null) "local" else "ssh")
                request.sourceWorkspaceID?.let { params.put("source_workspace_id", it) }
                "workspace.create"
            }
            is ResourceCreation.Terminal -> {
                params.put("workspace_id", request.workspaceID)
                request.tmuxSession?.let { params.put("tmux_session", it) }
                "mobile.terminal.create"
            }
        }
        val result = call(machine, method, params)
        val workspaceID = when (request) {
            is ResourceCreation.Workspace -> result.getString("created_workspace_id")
            is ResourceCreation.Terminal -> request.workspaceID
        }
        val windowID = if (request is ResourceCreation.Terminal) result.getString("created_terminal_id") else null
        return CreationResult(decodeMachine(machine, result), workspaceID, windowID)
    }

    override suspend fun replay(machine: Machine, workspaceID: String, windowID: String): TerminalSnapshot =
        decodeReplay(call(machine, "mobile.terminal.replay", target(workspaceID, windowID)), windowID)

    override suspend fun sendInput(machine: Machine, workspaceID: String, windowID: String, text: String) {
        require(text.isNotEmpty())
        require(text.toByteArray(Charsets.UTF_8).size <= MAX_INPUT_BYTES)
        val result = call(machine, "mobile.terminal.input", target(workspaceID, windowID).put("text", text))
        val actual = TerminalTarget(result.getString("workspace_id"), result.getString("surface_id"))
        if (!TerminalInputReceipt.accepts(TerminalTarget(workspaceID, windowID), actual, result.opt("queued") as? Boolean)) throw MachineFailure.InputNotQueued()
    }

    private fun decodeMachine(machine: Machine, result: JSONObject): MachineSnapshot {
        val workspaces = result.getJSONArray("workspaces").objects().map { workspace ->
            val terminals = workspace.getJSONArray("terminals").objects().map { terminal ->
                RemoteWindow(terminal.getString("id"), terminal.getString("title"), "terminal")
            }
            require(terminals.map { it.id }.distinct().size == terminals.size)
            val kind = when (workspace.optString("kind")) { "ssh" -> true; "local" -> false; else -> null }
            RemoteWorkspace(workspace.getString("id"), workspace.getString("title"), kind, terminals)
        }
        require(workspaces.map { it.id }.distinct().size == workspaces.size)
        return MachineSnapshot(result.optString("display_name", machine.name), workspaces)
    }

    private fun decodeReplay(result: JSONObject, windowID: String): TerminalSnapshot {
        require(result.getString("surface_id").equals(windowID, ignoreCase = true))
        val frame = decoder.decode(result.optJSONObject("render_grid") ?: throw MachineFailure.UnsupportedTerminal(), windowID)
        if (!frame.full) throw MachineFailure.UnsupportedTerminal()
        return frame.snapshot
    }

    private suspend fun call(machine: Machine, method: String, params: JSONObject): JSONObject =
        rpc.call(machine.endpoint, method, params).getJSONObject("result")
    private fun target(workspaceID: String, windowID: String) = JSONObject().put("workspace_id", workspaceID).put("surface_id", windowID)
    private fun JSONArray.objects() = List(length()) { getJSONObject(it) }
    companion object { const val MAX_INPUT_BYTES = 256 * 1024 }
}
