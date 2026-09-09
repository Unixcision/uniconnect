package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.FilePutLocation
import com.unixcision.uniconnect.android.domain.FilePutTransfer
import com.unixcision.uniconnect.android.domain.MachineFailure
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.MessageDigest
import java.util.Base64

/**
 * The `file_put.v1` RPCs as they cross the wire, against a host played on the other end of a
 * socket pair: methods, parameters, base64 data, the index sequence, the checksum and the
 * error path with its abort.
 */
class NativeFilePutClientTest {
    private val payload = ByteArray(12) { (it + 1).toByte() }

    @Test
    fun aWholeTransferSpeaksTheFourRpcsInOrder() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val host = scope.async {
                val begin = pair.read()
                assertEquals("mobile.file.begin", begin.getString("method"))
                val beginParams = begin.getJSONObject("params")
                assertEquals("ws-1", beginParams.getString("workspace_id"))
                assertEquals("win-1", beginParams.getString("terminal_id"))
                assertEquals("notas.txt", beginParams.getString("name"))
                assertEquals(12L, beginParams.getLong("size"))
                assertEquals("text/plain", beginParams.getString("mime"))
                pair.reply(begin, JSONObject().put("transfer_id", "t-9").put("chunk_bytes", 5))
                val received = mutableListOf<Byte>()
                for (expected in 0..2) {
                    val chunk = pair.read()
                    assertEquals("mobile.file.chunk", chunk.getString("method"))
                    val params = chunk.getJSONObject("params")
                    assertEquals("t-9", params.getString("transfer_id"))
                    assertEquals(expected, params.getInt("index"))
                    received += Base64.getDecoder().decode(params.getString("data")).toList()
                    pair.reply(chunk, JSONObject().put("received_bytes", received.size))
                }
                assertArrayEquals(payload, received.toByteArray())
                val commit = pair.read()
                assertEquals("mobile.file.commit", commit.getString("method"))
                assertEquals("t-9", commit.getJSONObject("params").getString("transfer_id"))
                assertEquals(FilePutTransfer.hex(MessageDigest.getInstance("SHA-256").digest(payload)), commit.getJSONObject("params").getString("sha256"))
                pair.reply(commit, JSONObject().put("path", "/Users/d/UniConnect/Entrada/20260909/notas.txt").put("location", "remote").put("remote_path", "/home/d/uniconnect-entrada/notas.txt"))
                // The session closes with the block: nothing else is sent.
                assertEquals(-1, pair.remote.getInputStream().read())
            }
            val outcome = FramedRpcSession(pair.local, scope).use { session ->
                FilePutTransfer.run(NativeFilePutClient.RpcFilePutSession(session), "ws-1", "win-1", "notas.txt", payload.size.toLong(), "text/plain", { ByteArrayInputStream(payload) }) {}
            }
            assertEquals(FilePutLocation.REMOTE, outcome.location)
            assertEquals("/home/d/uniconnect-entrada/notas.txt", outcome.pastePath)
            assertNull(outcome.remoteError)
            withTimeout(3_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    @Test
    fun aHostErrorOnAChunkBecomesTheCodeAndAnAbortFollowsOnAFreshSession() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        // The framed session closes itself on the refused call, so the abort arrives on a second connection.
        val second = SocketPair()
        try {
            val host = scope.async {
                val begin = pair.read()
                pair.reply(begin, JSONObject().put("transfer_id", "t-2").put("chunk_bytes", 5))
                val first = pair.read()
                assertEquals(0, first.getJSONObject("params").getInt("index"))
                pair.reply(first, JSONObject().put("received_bytes", 5))
                val refused = pair.read()
                assertEquals(1, refused.getJSONObject("params").getInt("index"))
                pair.write(JSONObject().put("id", refused.getString("id")).put("ok", false).put("error", JSONObject().put("code", "io_failed").put("message", "disco lleno")))
                // Nothing more on the first connection: it is closed by the phone.
                assertEquals(-1, pair.remote.getInputStream().read())
                val abort = second.read()
                assertEquals("mobile.file.abort", abort.getString("method"))
                assertEquals("t-2", abort.getJSONObject("params").getString("transfer_id"))
                second.reply(abort, JSONObject())
            }
            try {
                FramedRpcSession(pair.local, scope).use { session ->
                    FilePutTransfer.run(NativeFilePutClient.RpcFilePutSession(session) { FramedRpcSession(second.local, scope) }, "ws-1", null, "x.bin", payload.size.toLong(), null, { ByteArrayInputStream(payload) }) {}
                }
                fail("expected io_failed")
            } catch (e: MachineFailure.Rejected) {
                assertEquals("io_failed", e.code)
                assertEquals("disco lleno", e.detail)
            }
            withTimeout(3_000) { host.await() }
        } finally { pair.close(); second.close(); scope.cancel() }
    }

    @Test
    fun aHostCopyThatFailedStillGivesTheHostPath() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val host = scope.async {
                val begin = pair.read()
                pair.reply(begin, JSONObject().put("transfer_id", "t-3").put("chunk_bytes", 1024))
                val chunk = pair.read()
                pair.reply(chunk, JSONObject().put("received_bytes", 12))
                val commit = pair.read()
                pair.reply(commit, JSONObject().put("path", "/Users/d/UniConnect/Entrada/20260909/x.bin").put("location", "host").put("remote_error", "scp: Connection refused"))
            }
            val outcome = FramedRpcSession(pair.local, scope).use { session ->
                FilePutTransfer.run(NativeFilePutClient.RpcFilePutSession(session), "ws-1", null, "x.bin", payload.size.toLong(), null, { ByteArrayInputStream(payload) }) {}
            }
            assertEquals(FilePutLocation.HOST, outcome.location)
            assertEquals("/Users/d/UniConnect/Entrada/20260909/x.bin", outcome.pastePath)
            assertEquals("scp: Connection refused", outcome.remoteError)
            assertFalse(outcome.pastePath.contains("uniconnect-entrada"))
            withTimeout(3_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

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
            val bytes = ByteArray(input.readInt().also { require(it in 1..65536) })
            input.readFully(bytes)
            return JSONObject(String(bytes, Charsets.UTF_8))
        }
        fun write(value: JSONObject) {
            val bytes = value.toString().toByteArray(Charsets.UTF_8)
            DataOutputStream(remote.getOutputStream()).apply { writeInt(bytes.size); write(bytes); flush() }
        }
        fun reply(request: JSONObject, result: JSONObject) = write(JSONObject().put("id", request.getString("id")).put("ok", true).put("result", result))
        override fun close() { local.close(); remote.close() }
    }
}
