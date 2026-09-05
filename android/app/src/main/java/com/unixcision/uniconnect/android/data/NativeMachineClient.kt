package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.*
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray
import org.json.JSONObject

/** The host approves the observed peer IP. This client never sends SSH secrets or creates on attach. */
class NativeMachineClient(private val rpc: FramedRpcClient) : MachineClient {
    private val decoder = TerminalFrameDecoder()

    override fun observe(machine: Machine, terminal: TerminalTarget?): Flow<MachineUpdate> = flow {
        rpc.open(machine.endpoint).use { session ->
            emitAll(observeSession(session, machine, terminal))
        }
    }.catch { failure ->
        if (failure is org.json.JSONException || failure is IllegalArgumentException) throw MachineFailure.ProtocolMismatch()
        throw failure
    }.flowOn(Dispatchers.Default)

    internal fun observeSession(session: FramedRpcSession, machine: Machine, terminal: TerminalTarget?): Flow<MachineUpdate> = flow {
            subscribe(session, terminal)
            val updateWorkspaces: suspend () -> Unit = {
                emit(MachineUpdate.Workspaces(decodeMachine(machine, session.call("mobile.workspace.list", JSONObject()).value.getJSONObject("result"))))
            }
            updateWorkspaces()
            var screen: TerminalSnapshot? = null
            var replayOrdinal = 0L
            if (terminal != null) {
                val replay = requestReplay(session, terminal, updateWorkspaces)
                screen = replay.snapshot
                replayOrdinal = replay.ordinal
                emit(MachineUpdate.Terminal(screen))
            }
            while (true) {
                val first = session.nextEventOrHeartbeat(15_000)
                val events = if (first == null) emptyList() else listOf(first) + session.drainQueuedEvents()
                // A bounded RPC heartbeat detects silent network loss even when the desktop is idle.
                if (first == null || events.any { it.value.optString("topic") == "workspace.updated" }) {
                    updateWorkspaces()
                }
                if (terminal == null) continue
                var needsReplay = false
                for (event in events) {
                    if (event.value.optString("topic") == "terminal.updated") {
                        // Linux invalidates globally. Reading the selected surface never creates or attaches a tmux.
                        val changedID = event.value.optJSONObject("payload")?.optString("surface_id").orEmpty()
                        if (changedID.isEmpty() || changedID.equals(terminal.windowID, ignoreCase = true)) needsReplay = true
                        continue
                    }
                    if (event.value.optString("topic") != "terminal.render_grid") continue
                    val payload = event.value.getJSONObject("payload")
                    val grid = payload.optJSONObject("render_grid") ?: payload
                    if (!grid.optString("surface_id").equals(terminal.windowID, ignoreCase = true)) continue
                    val frame = decoder.decode(grid, terminal.windowID)
                    // A revision supersedes response order: event 3 can precede the response for replay 2.
                    if (frame.snapshot.revision == null && event.ordinal <= replayOrdinal) continue
                    screen = try { frame.applyingTo(screen).also { if (frame.full) needsReplay = false } }
                    catch (_: TerminalFrame.FullReplayRequired) { needsReplay = true; screen }
                }
                if (needsReplay) {
                    val replay = requestReplay(session, terminal, updateWorkspaces)
                    replayOrdinal = replay.ordinal
                    screen = TerminalFrame(replay.snapshot, true, emptySet()).applyingTo(screen)
                }
                if (events.isNotEmpty()) emit(MachineUpdate.Terminal(requireNotNull(screen)))
            }
    }

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
        rpc.open(machine.endpoint).use { session ->
            val terminal = TerminalTarget(workspaceID, windowID)
            subscribe(session, terminal)
            requestReplay(session, terminal).snapshot
        }

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

    private fun decodeReplay(result: JSONObject, windowID: String): TerminalSnapshot? {
        require(result.getString("surface_id").equals(windowID, ignoreCase = true))
        if (result.opt("is_ready") == false) return null
        val frame = decoder.decode(result.optJSONObject("render_grid") ?: throw MachineFailure.UnsupportedTerminal(), windowID)
        if (!frame.full) throw MachineFailure.UnsupportedTerminal()
        return frame.snapshot
    }

    private suspend fun subscribe(session: FramedRpcSession, terminal: TerminalTarget?) {
        val streamID = UUID.randomUUID().toString()
        val topics = JSONArray().put("workspace.updated")
        if (terminal != null) topics.put("terminal.render_grid").put("terminal.updated")
        val subscribed = session.call("mobile.events.subscribe", JSONObject().put("stream_id", streamID).put("topics", topics))
        require(subscribed.value.getJSONObject("result").getString("stream_id") == streamID)
    }

    /** Cold surfaces complete through their existing subscription, never another create/attach or replay poll. */
    internal suspend fun requestReplay(
        session: FramedRpcSession,
        terminal: TerminalTarget,
        updateWorkspaces: suspend () -> Unit = {},
    ): ReplayScreen {
        var waitingForSurface = false
        return try {
            transportDeadline(12_000) {
                val reply = session.call("mobile.terminal.replay", target(terminal.workspaceID, terminal.windowID))
                val result = reply.value.getJSONObject("result")
                require(result.getString("workspace_id").equals(terminal.workspaceID, ignoreCase = true))
                decodeReplay(result, terminal.windowID)?.let { return@transportDeadline ReplayScreen(it, reply.ordinal) }
                waitingForSurface = true
                var ready: ReplayScreen? = null
                while (ready == null) {
                    val event = session.nextEventOrHeartbeat(12_000) ?: throw MachineFailure.DeadlineExceeded()
                    when (event.value.optString("topic")) {
                        "workspace.updated" -> updateWorkspaces()
                        "terminal.render_grid" -> {
                            val payload = event.value.getJSONObject("payload")
                            val grid = payload.optJSONObject("render_grid") ?: payload
                            if (!grid.optString("surface_id").equals(terminal.windowID, ignoreCase = true)) continue
                            val frame = decoder.decode(grid, terminal.windowID)
                            if (frame.full) ready = ReplayScreen(frame.snapshot, event.ordinal)
                        }
                    }
                }
                ready
            }
        } catch (failure: MachineFailure.DeadlineExceeded) {
            if (waitingForSurface) throw MachineFailure.TerminalNotReady()
            throw failure
        }
    }

    internal data class ReplayScreen(val snapshot: TerminalSnapshot, val ordinal: Long)

    private suspend fun call(machine: Machine, method: String, params: JSONObject): JSONObject =
        rpc.call(machine.endpoint, method, params).getJSONObject("result")
    private fun target(workspaceID: String, windowID: String) = JSONObject().put("workspace_id", workspaceID).put("surface_id", windowID)
    private fun JSONArray.objects() = List(length()) { getJSONObject(it) }
    companion object { const val MAX_INPUT_BYTES = 256 * 1024 }
}
