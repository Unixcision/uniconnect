package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.FilePutClient
import com.unixcision.uniconnect.android.domain.FilePutLocation
import com.unixcision.uniconnect.android.domain.FilePutOutcome
import com.unixcision.uniconnect.android.domain.FilePutSession
import com.unixcision.uniconnect.android.domain.FilePutTicket
import com.unixcision.uniconnect.android.domain.FilePutTransfer
import com.unixcision.uniconnect.android.domain.Machine
import org.json.JSONObject
import java.util.Base64

/**
 * `file_put.v1` over the framed RPC session the app already speaks: one TCP connection per
 * transfer, chunks as base64 inside JSON. A 1 MiB chunk is 1.4 MiB encoded, well under the 8 MiB
 * frame limit; anything the host asks beyond the contract's ceiling is cut down before encoding.
 */
class NativeFilePutClient(private val rpc: FramedRpcClient) : FilePutClient {
    override suspend fun <T> withSession(machine: Machine, block: suspend (FilePutSession) -> T): T =
        rpc.open(machine.endpoint).use { session -> block(RpcFilePutSession(session) { rpc.open(machine.endpoint) }) }

    /**
     * The four RPCs on one open session; the session's own errors surface as
     * [com.unixcision.uniconnect.android.domain.MachineFailure]. A framed session closes itself on
     * any failed call, so an abort after a refused chunk travels on a session [reopen] gives.
     */
    internal class RpcFilePutSession(private val session: FramedRpcSession, private val reopen: (suspend () -> FramedRpcSession)? = null) : FilePutSession {
        override suspend fun begin(workspaceID: String, terminalID: String?, name: String, size: Long, mime: String?): FilePutTicket {
            val params = JSONObject().put("workspace_id", workspaceID).put("name", name).put("size", size)
            terminalID?.let { params.put("terminal_id", it) }
            mime?.let { params.put("mime", it) }
            val result = call("mobile.file.begin", params)
            return FilePutTicket(result.getString("transfer_id"), result.optInt("chunk_bytes", FilePutTransfer.MAX_CHUNK_BYTES).coerceIn(1, FilePutTransfer.MAX_CHUNK_BYTES))
        }

        override suspend fun chunk(transferID: String, index: Int, data: ByteArray): Long {
            require(data.size <= FilePutTransfer.MAX_CHUNK_BYTES) { "a chunk is at most 1 MiB" }
            val params = JSONObject().put("transfer_id", transferID).put("index", index).put("data", Base64.getEncoder().encodeToString(data))
            return call("mobile.file.chunk", params, deadlineMillis = CHUNK_DEADLINE_MILLIS).optLong("received_bytes", -1)
        }

        override suspend fun commit(transferID: String, sha256: String): FilePutOutcome {
            val result = call("mobile.file.commit", JSONObject().put("transfer_id", transferID).put("sha256", sha256), deadlineMillis = COMMIT_DEADLINE_MILLIS)
            return FilePutOutcome(
                path = result.getString("path"),
                location = if (result.optString("location") == "remote") FilePutLocation.REMOTE else FilePutLocation.HOST,
                remotePath = result.optString("remote_path").takeIf { it.isNotEmpty() },
                remoteError = result.optString("remote_error").takeIf { it.isNotEmpty() },
            )
        }

        override suspend fun abort(transferID: String) {
            val params = JSONObject().put("transfer_id", transferID)
            try {
                call("mobile.file.abort", params)
            } catch (e: IllegalStateException) {
                // The session already closed on the failure that led here: tell the host on a fresh one.
                reopen?.invoke()?.use { fresh -> fresh.call("mobile.file.abort", params) }
            }
        }

        private suspend fun call(method: String, params: JSONObject, deadlineMillis: Long = 12_000): JSONObject =
            session.call(method, params, deadlineMillis).value.getJSONObject("result")
    }

    private companion object {
        /** A chunk crosses the tailnet at whatever speed the phone has; a minute covers 1 MiB at a slow 20 KB/s. */
        const val CHUNK_DEADLINE_MILLIS = 60_000L

        /** The commit may carry an scp to the SSH server, which takes as long as that copy does. */
        const val COMMIT_DEADLINE_MILLIS = 120_000L
    }
}
