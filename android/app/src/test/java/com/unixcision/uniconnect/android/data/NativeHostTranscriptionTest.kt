package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.AudioPayload
import com.unixcision.uniconnect.android.domain.DictationTarget
import com.unixcision.uniconnect.android.domain.Machine
import com.unixcision.uniconnect.android.domain.MachineEndpoint
import com.unixcision.uniconnect.android.domain.TranscribeRefusal
import com.unixcision.uniconnect.android.domain.TranscribeRefused
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.io.DataInputStream
import java.io.DataOutputStream
import java.util.Base64
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
import org.junit.Assert.assertThrows
import org.junit.Assert.fail
import org.junit.Test

/**
 * `mobile.audio.transcribe` as it crosses the wire, against a host played on the other end of a
 * socket pair: the parameters, the audio that comes out the same as it went in, the text that
 * comes back, and the recording that is refused here instead of breaking a frame.
 */
class NativeHostTranscriptionTest {
    private val target = DictationTarget(
        Machine("m1", "MINIPC", MachineEndpoint.parse("100.64.0.1", "58465")!!),
        "ws-1",
        "win-1",
    )

    @Test
    fun theRecordingTravelsWholeAndTheTextComesBack() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        val audio = ByteArray(9_000) { (it * 7 % 253).toByte() }
        try {
            val host = scope.async {
                val request = pair.read()
                assertEquals("mobile.audio.transcribe", request.getString("method"))
                val params = request.getJSONObject("params")
                assertEquals("audio/mp4", params.getString("mime"))
                assertEquals("ws-1", params.getString("workspace_id"))
                assertEquals("win-1", params.getString("terminal_id"))
                assertEquals("es", params.getString("language"))
                assertArrayEquals(audio, Base64.getDecoder().decode(params.getString("audio")))
                pair.reply(request, JSONObject().put("text", " git status ").put("engine", "whisper.cpp").put("seconds", 12.5).put("took_ms", 1_800))
            }
            val transcript = FramedRpcSession(pair.local, scope).use { session ->
                NativeHostTranscription(FramedRpcClient(scope)).over(session, target, audio, "audio/mp4", "es")
            }
            assertEquals(" git status ", transcript.text)
            assertEquals("whisper.cpp", transcript.engine)
            assertEquals(12.5, transcript.seconds, 0.001)
            assertEquals(1_800L, transcript.tookMillis)
            withTimeout(3_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    @Test
    fun aLanguageIsLeftOutWhenTheMachineIsToDecide() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val host = scope.async {
                val request = pair.read()
                assertEquals(false, request.getJSONObject("params").has("language"))
                pair.reply(request, JSONObject().put("text", "hola"))
            }
            val transcript = FramedRpcSession(pair.local, scope).use { session ->
                NativeHostTranscription(FramedRpcClient(scope)).over(session, target, ByteArray(64), "audio/mp4", null)
            }
            assertEquals("hola", transcript.text)
            withTimeout(3_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    @Test
    fun everyErrorOfTheContractComesBackAsItsOwnRefusal() = runBlocking {
        listOf("too_large" to TranscribeRefusal.TOO_LARGE, "unsupported" to TranscribeRefusal.UNSUPPORTED, "locked" to TranscribeRefusal.LOCKED, "io_failed" to TranscribeRefusal.IO_FAILED, "vaya" to TranscribeRefusal.UNKNOWN).forEach { (code, expected) ->
            val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
            val pair = SocketPair()
            try {
                val host = scope.async {
                    val request = pair.read()
                    pair.write(JSONObject().put("id", request.getString("id")).put("ok", false).put("error", JSONObject().put("code", code).put("message", "no ha podido ser")))
                }
                try {
                    FramedRpcSession(pair.local, scope).use { session ->
                        NativeHostTranscription(FramedRpcClient(scope)).over(session, target, ByteArray(64), "audio/mp4", "es")
                    }
                    fail("expected $code")
                } catch (refused: TranscribeRefused) {
                    assertEquals(code, expected, refused.refusal)
                    assertEquals("no ha podido ser", refused.detail)
                }
                withTimeout(3_000) { host.await() }
            } finally { pair.close(); scope.cancel() }
        }
    }

    @Test
    fun aRecordingOverTheCeilingNeverReachesTheSocket() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val refused = assertThrows(TranscribeRefused::class.java) {
                runBlocking {
                    FramedRpcSession(pair.local, scope).use { session ->
                        NativeHostTranscription(FramedRpcClient(scope))
                            .over(session, target, ByteArray((AudioPayload.MAX_AUDIO_BYTES + 1).toInt()), "audio/mp4", "es")
                    }
                }
            }
            assertEquals(TranscribeRefusal.TOO_LARGE, refused.refusal)
            assertEquals("the host was never asked", 0, pair.remote.getInputStream().available())
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
            val bytes = ByteArray(input.readInt().also { require(it in 1..FramedRpcClient.MAX_FRAME_BYTES) })
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
