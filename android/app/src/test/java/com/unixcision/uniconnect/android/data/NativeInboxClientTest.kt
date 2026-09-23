package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.InboxDeletion
import com.unixcision.uniconnect.android.domain.InboxKind
import com.unixcision.uniconnect.android.domain.MachineFailure
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.DataInputStream
import java.io.DataOutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import java.util.Base64

/** `inbox.v1` tal como cruza el cable, contra un equipo simulado al otro lado de un socket. */
class NativeInboxClientTest {
    @Test
    fun laListaSeLeeComoLaDaElEquipo() {
        val listing = NativeInboxClient.parseListing(JSONObject("""
            {"root":"/home/d/UniConnect/Entrada","count":3,"total_bytes":360,"oldest":100,"newest":300,
             "entries":[
               {"path":"20260923/video.mp4","absolute":"/home/d/UniConnect/Entrada/20260923/video.mp4","name":"video.mp4","size":300,"modified":300,"kind":"video"},
               {"path":"20260922/foto.JPG","absolute":"/a/foto.JPG","name":"foto.JPG","size":50,"modified":200,"kind":"image"},
               {"path":"","absolute":"/x","name":"sin ruta","size":1,"modified":1,"kind":"image"},
               {"path":"20260901/raro.bin","absolute":"/a/raro.bin","size":10,"modified":100,"kind":"lo-que-sea"}
             ]}
        """.trimIndent()))
        assertEquals(3, listing.count)
        assertEquals(360L, listing.totalBytes)
        assertEquals(100L, listing.oldest)
        assertEquals(listOf("video.mp4", "foto.JPG", "raro.bin"), listing.entries.map { it.name })
        assertEquals(listOf(InboxKind.VIDEO, InboxKind.IMAGE, InboxKind.OTHER), listing.entries.map { it.kind })
        assertEquals("/home/d/UniConnect/Entrada/20260923/video.mp4", listing.entries[0].absolute)
    }

    @Test
    fun unaBandejaVaciaNoTraeFechas() {
        val listing = NativeInboxClient.parseListing(JSONObject("""{"count":0,"total_bytes":0,"oldest":null,"newest":null,"entries":[]}"""))
        assertEquals(0, listing.count)
        assertNull(listing.oldest)
        assertNull(listing.newest)
        assertTrue(listing.entries.isEmpty())
    }

    @Test
    fun borrarMandaSoloLosCriteriosElegidos() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val host = scope.async {
                val request = pair.read()
                assertEquals("mobile.inbox.delete", request.getString("method"))
                val params = request.getJSONObject("params")
                assertEquals(7, params.getInt("older_than_days"))
                assertEquals(5_000_000L, params.getLong("larger_than_bytes"))
                assertTrue(params.getBoolean("dry_run"))
                assertFalse("sin «todo» no se manda «all»", params.has("all"))
                assertFalse(params.has("paths"))
                pair.reply(request, JSONObject().put("dry_run", true).put("deleted", 2).put("freed_bytes", 12_000_000L)
                    .put("remaining_count", 5).put("remaining_bytes", 900L))
            }
            val result = FramedRpcSession(pair.local, scope).use { session ->
                NativeInboxClient.RpcInboxSession(session).delete(InboxDeletion(olderThanDays = 7, largerThanBytes = 5_000_000L, dryRun = true))
            }
            assertTrue(result.dryRun)
            assertEquals(2, result.deleted)
            assertEquals(12_000_000L, result.freedBytes)
            assertEquals(5, result.remainingCount)
            withTimeout(3_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    @Test
    fun borrarRutasConcretasLasMandaEnLista() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            val host = scope.async {
                val request = pair.read()
                val params = request.getJSONObject("params")
                assertEquals(JSONArray(listOf("20260923/a.jpg")).toString(), params.getJSONArray("paths").toString())
                assertFalse(params.getBoolean("dry_run"))
                pair.reply(request, JSONObject().put("deleted", 1).put("freed_bytes", 3))
            }
            FramedRpcSession(pair.local, scope).use { session ->
                NativeInboxClient.RpcInboxSession(session).delete(InboxDeletion(paths = listOf("20260923/a.jpg")))
            }
            withTimeout(3_000) { host.await() }
        } finally { pair.close(); scope.cancel() }
    }

    @Test
    fun laDescargaJuntaLosTrozosYSoloAlFinalApareceElArchivo() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        val folder = Files.createTempDirectory("uc-inbox").toFile()
        val contenido = ByteArray(2_500) { (it % 251).toByte() }
        val destino = folder.resolve("vistas/foto.jpg")
        try {
            val host = scope.async {
                var offset = 0
                while (true) {
                    val request = pair.read()
                    assertEquals("mobile.inbox.read", request.getString("method"))
                    val params = request.getJSONObject("params")
                    assertEquals("20260923/foto.jpg", params.getString("path"))
                    assertEquals(offset.toLong(), params.getLong("offset"))
                    assertFalse("a medias el archivo final no existe", destino.exists())
                    // El equipo corta a 1000 aunque se pida 1 MiB, como haría con un trozo máximo.
                    val trozo = contenido.copyOfRange(offset, minOf(offset + 1000, contenido.size))
                    offset += trozo.size
                    pair.reply(request, JSONObject().put("size", contenido.size).put("offset", offset - trozo.size)
                        .put("data", Base64.getEncoder().encodeToString(trozo)).put("eof", offset >= contenido.size))
                    if (offset >= contenido.size) break
                }
            }
            val vistos = mutableListOf<Long>()
            FramedRpcSession(pair.local, scope).use { session ->
                NativeInboxClient.RpcInboxSession(session).download(entry("20260923/foto.jpg", 2_500), destino) { vistos += it }
            }
            withTimeout(3_000) { host.await() }
            assertArrayEquals(contenido, destino.readBytes())
            assertEquals(listOf(1000L, 2000L, 2500L), vistos)
            assertFalse(folder.resolve("vistas/foto.jpg.part").exists())
        } finally { pair.close(); scope.cancel(); folder.deleteRecursively() }
    }

    @Test
    fun unEquipoQueNoAvanzaCortaLaDescargaSinDejarBasura() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        val folder = Files.createTempDirectory("uc-inbox").toFile()
        val destino = folder.resolve("foto.jpg")
        try {
            scope.async {
                val request = pair.read()
                pair.reply(request, JSONObject().put("size", 100).put("offset", 0).put("data", "").put("eof", false))
            }
            try {
                FramedRpcSession(pair.local, scope).use { session ->
                    NativeInboxClient.RpcInboxSession(session).download(entry("20260923/foto.jpg", 100), destino) {}
                }
                fail("un trozo vacío antes del final no puede darse por bueno")
            } catch (expected: MachineFailure.ProtocolMismatch) {
            }
            assertFalse(destino.exists())
            assertFalse(folder.resolve("foto.jpg.part").exists())
        } finally { pair.close(); scope.cancel(); folder.deleteRecursively() }
    }

    @Test
    fun unErrorDelEquipoLlegaConSuCodigo() = runBlocking {
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
        val pair = SocketPair()
        try {
            scope.async {
                val request = pair.read()
                pair.write(JSONObject().put("id", request.getString("id")).put("ok", false)
                    .put("error", JSONObject().put("code", "approval_required").put("message", "Aprueba este móvil")))
            }
            try {
                FramedRpcSession(pair.local, scope).use { session -> NativeInboxClient.RpcInboxSession(session).list(200, 0) }
                fail("sin permiso no hay lista")
            } catch (rejected: MachineFailure.Rejected) {
                assertEquals("approval_required", rejected.code)
            }
        } finally { pair.close(); scope.cancel() }
    }

    private fun entry(path: String, size: Long) =
        com.unixcision.uniconnect.android.domain.InboxEntry(path, "/x/$path", path.substringAfterLast('/'), size, 0, InboxKind.IMAGE)

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
