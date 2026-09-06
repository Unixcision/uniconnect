package com.unixcision.uniconnect.android.data

import android.util.Base64
import com.unixcision.uniconnect.android.domain.MachineFailure
import com.unixcision.uniconnect.android.domain.PtyEvent
import com.unixcision.uniconnect.android.domain.TerminalAttachment
import java.util.UUID
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import org.json.JSONArray
import org.json.JSONObject

/**
 * Attach RPC over one [FramedRpcSession]: `mobile.terminal.attach`, `terminal.pty` events,
 * `mobile.terminal.pty_input`, `mobile.terminal.pty_resize`, `mobile.terminal.detach`.
 * The session is owned here so input and output share the connection the host bound the
 * attachment to; closing the session is what detaches on the host.
 */
class NativeTerminalAttachment private constructor(
    private val session: FramedRpcSession,
    override val attachID: String,
    private val surfaceID: String,
    override val columns: Int,
    override val rows: Int,
) : TerminalAttachment {

    override val events: Flow<PtyEvent> = flow {
        var lastSeq = -1L
        while (true) {
            val first = session.nextEventOrHeartbeat(15_000) ?: continue
            for (event in listOf(first) + session.drainQueuedEvents()) {
                if (event.value.optString("topic") != TOPIC) continue
                val payload = event.value.optJSONObject("payload") ?: continue
                if (!payload.optString("attach_id").equals(attachID, ignoreCase = true)) continue
                val seq = payload.optLong("seq", -1)
                // Chunks arrive in order on one socket; a repeated seq is a host retry we drop.
                if (seq >= 0 && seq <= lastSeq) continue
                if (seq >= 0) lastSeq = seq
                if (payload.optBoolean("exit", false)) { emit(PtyEvent.Exit); return@flow }
                // Geometry travels in the same event and must be applied before its bytes, so the
                // emulator is already the right size when the redraw that follows arrives.
                val presentationColumns = payload.optInt("presentation_columns", 0)
                val presentationRows = payload.optInt("presentation_rows", 0)
                if (presentationColumns in 1..1000 && presentationRows in 1..1000) {
                    emit(
                        PtyEvent.Geometry(
                            presentationColumns, presentationRows,
                            payload.optInt("source_columns", presentationColumns).coerceIn(1, 1000),
                            payload.optInt("source_rows", presentationRows).coerceIn(1, 1000),
                        )
                    )
                }
                val data = payload.optString("data")
                if (data.isNotEmpty()) emit(PtyEvent.Output(Base64.decode(data, Base64.NO_WRAP)))
            }
        }
    }.flowOn(Dispatchers.Default)

    override suspend fun send(bytes: ByteArray) {
        require(bytes.isNotEmpty() && bytes.size <= MAX_INPUT_BYTES)
        val result = session.call(INPUT, JSONObject().put("attach_id", attachID).put("data", Base64.encodeToString(bytes, Base64.NO_WRAP)))
            .value.getJSONObject("result")
        if (result.opt("queued") != true) throw MachineFailure.InputNotQueued()
    }

    override suspend fun resize(columns: Int, rows: Int) {
        require(columns in 1..1000 && rows in 1..1000)
        session.call(RESIZE, JSONObject().put("attach_id", attachID).put("columns", columns).put("rows", rows))
    }

    override fun close() {
        // Detach is best effort: the host also detaches when this socket closes.
        session.close()
    }

    companion object {
        const val METHOD = "mobile.terminal.attach"
        const val INPUT = "mobile.terminal.pty_input"
        const val RESIZE = "mobile.terminal.pty_resize"
        const val DETACH = "mobile.terminal.detach"
        const val TOPIC = "terminal.pty"
        const val MAX_INPUT_BYTES = 64 * 1024

        /** Subscribes, attaches and returns the live attachment; the session is closed on failure. */
        suspend fun open(session: FramedRpcSession, workspaceID: String, windowID: String, columns: Int, rows: Int): NativeTerminalAttachment {
            try {
                val streamID = UUID.randomUUID().toString()
                val subscribed = session.call("mobile.events.subscribe", JSONObject().put("stream_id", streamID).put("topics", JSONArray().put(TOPIC).put("workspace.updated")))
                require(subscribed.value.getJSONObject("result").getString("stream_id") == streamID)
                val params = JSONObject().put("workspace_id", workspaceID).put("surface_id", windowID)
                    .put("columns", columns).put("rows", rows).put("client_id", UUID.randomUUID().toString())
                val result = session.call(METHOD, params).value.getJSONObject("result")
                require(result.getString("surface_id").equals(windowID, ignoreCase = true))
                val attachID = result.getString("attach_id").also { require(it.isNotBlank()) }
                return NativeTerminalAttachment(session, attachID, windowID, result.optInt("columns", columns), result.optInt("rows", rows))
            } catch (failure: Exception) {
                session.close()
                throw failure
            }
        }
    }
}
