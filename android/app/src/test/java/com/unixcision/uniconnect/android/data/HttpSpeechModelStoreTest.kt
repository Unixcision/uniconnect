package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.SpeechModel
import com.unixcision.uniconnect.android.domain.SpeechModelFailure
import com.unixcision.uniconnect.android.domain.SpeechModelState
import java.io.BufferedInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.file.Files
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * Fetching a model against a local server: what lands on disk, what a cut download leaves behind,
 * and every way of refusing what arrived.
 *
 * The real files are 57 and 181 megabytes, so the store is told a smaller size here and the server
 * serves exactly that; everything else, including the resume and the checks, is what runs on the
 * phone. The server is a few lines over a [ServerSocket] because Android's unit-test `android.jar`
 * has no `com.sun.net.httpserver`.
 */
class HttpSpeechModelStoreTest {
    private lateinit var directory: File
    private lateinit var server: RangeServer
    private val scope = CoroutineScope(Dispatchers.Unconfined)

    /** A model that starts with ggml's magic, as the real ones do. */
    private val body = SpeechModel.MAGIC + ByteArray(4_096) { (it % 251).toByte() }

    @Before
    fun start() {
        directory = Files.createTempDirectory("whisper-models").toFile()
        server = RangeServer(body)
        server.start()
    }

    @After
    fun stop() {
        server.stop()
        directory.deleteRecursively()
    }

    private fun store(size: Long = body.size.toLong()) =
        HttpSpeechModelStore(directory, scope, "http://127.0.0.1:${server.port}/", Dispatchers.Unconfined) { size }

    private fun fetch(store: HttpSpeechModelStore, model: SpeechModel = SpeechModel.BASE): SpeechModelState {
        runBlocking { store.download(model) }
        return store.states.value.getValue(model)
    }

    @Test
    fun aModelIsFetchedWholeAndVerifiedBeforeItCounts() {
        val store = store()
        assertEquals(SpeechModelState.Missing, store.states.value.getValue(SpeechModel.BASE))
        assertEquals(SpeechModelState.Ready(body.size.toLong()), fetch(store))
        assertEquals(SpeechModel.BASE, store.ready)
        val file = File(directory, SpeechModel.BASE.file)
        assertArrayEquals("what was asked for, byte for byte", body, file.readBytes())
        assertEquals(file.absolutePath, store.path(SpeechModel.BASE))
        assertFalse("the half-written file is gone", File(directory, SpeechModel.BASE.file + ".part").exists())
    }

    @Test
    fun aCutDownloadKeepsWhatItGotAndTheNextOneAsksForTheRest() {
        server.cutAfter = 1_000
        val store = store()
        // Whether the platform reads a hang-up as a short body or as a broken connection is its
        // own business; what matters is that the thousand bytes stay and the model is not offered.
        val failed = fetch(store) as SpeechModelState.Failed
        assertEquals(1_000L, failed.downloaded)
        assertNull("half a model is not a model", store.ready)

        server.cutAfter = 0
        assertEquals(SpeechModelState.Ready(body.size.toLong()), fetch(store))
        assertEquals("the second request asked only for the rest", "bytes=1000-", server.lastRange)
        assertArrayEquals("the two halves are one file", body, File(directory, SpeechModel.BASE.file).readBytes())
    }

    @Test
    fun aFileOfTheWrongSizeIsNeverOfferedAsTheModel() {
        // The store is told the model is longer than what the server has.
        val state = fetch(store(size = body.size + 10L))
        assertEquals(SpeechModelState.Failed(SpeechModelFailure.CORRUPT, 0), state)
        assertNull(store(size = body.size + 10L).ready)
    }

    @Test
    fun somethingThatIsNotAGgmlFileIsRefusedEvenAtTheRightSize() {
        server.body = ByteArray(body.size) { 0x41 }
        assertEquals(SpeechModelState.Failed(SpeechModelFailure.CORRUPT, body.size.toLong()), fetch(store()))
        assertFalse("nothing is renamed into place", File(directory, SpeechModel.BASE.file).exists())
    }

    @Test
    fun aServerThatRefusesTheRequestIsANetworkFailureThatKeepsNothing() {
        server.status = 404
        // The reason the server gave travels with the failure: "check your connection" on its own
        // is what an app says when it has not looked.
        assertEquals(SpeechModelState.Failed(SpeechModelFailure.NETWORK, 0, "HTTP 404"), fetch(store()))
    }

    @Test
    fun aWholeFileLeftUnnamedIsFinishedWithoutAskingTheServerAgain() {
        // The app was killed between the last byte and the rename: every byte is on disk under the
        // .part name. Resuming from the end of it earns an HTTP 416 and nothing else, for ever.
        File(directory, SpeechModel.BASE.file + ".part").writeBytes(body)
        val store = store()
        assertEquals(SpeechModelState.Ready(body.size.toLong()), fetch(store))
        assertEquals("the server was never asked", 0, server.requests)
        assertArrayEquals(body, File(directory, SpeechModel.BASE.file).readBytes())
    }

    @Test
    fun aRangeTheServerWillNotSatisfyThrowsAwayThePieceInsteadOfRetryingForEver() {
        File(directory, SpeechModel.BASE.file + ".part").writeBytes(body.copyOf(1_000))
        server.status = 416
        val store = store()
        assertEquals(SpeechModelState.Failed(SpeechModelFailure.CORRUPT, 0, "HTTP 416"), fetch(store))
        assertFalse("the piece that no server accepts is gone", File(directory, SpeechModel.BASE.file + ".part").exists())

        server.status = 200
        assertEquals("and the next attempt starts clean", SpeechModelState.Ready(body.size.toLong()), fetch(store))
    }

    @Test
    fun aServerThatIgnoresTheRangeStartsTheFileAgainInsteadOfCorruptingIt() {
        server.cutAfter = 1_000
        val store = store()
        fetch(store)
        server.cutAfter = 0
        server.ignoreRange = true
        assertEquals(SpeechModelState.Ready(body.size.toLong()), fetch(store))
        assertArrayEquals("appending to the old half would have doubled a kilobyte", body, File(directory, SpeechModel.BASE.file).readBytes())
    }

    @Test
    fun deletingTakesTheModelAndAnythingHalfFetchedWithIt() {
        val store = store()
        fetch(store)
        store.delete(SpeechModel.BASE)
        assertEquals(SpeechModelState.Missing, store.states.value.getValue(SpeechModel.BASE))
        assertNull(store.ready)
        assertFalse(File(directory, SpeechModel.BASE.file).exists())
    }

    @Test
    fun whatIsAlreadyOnDiskIsReadWithoutTouchingTheNetwork() {
        fetch(store())
        server.stop()
        val reopened = store()
        assertEquals(SpeechModelState.Ready(body.size.toLong()), reopened.states.value.getValue(SpeechModel.BASE))
        assertEquals(SpeechModel.BASE, reopened.ready)
    }

    @Test
    fun aHalfFetchedFileIsReadBackAsADownloadToCarryOn() {
        File(directory, SpeechModel.SMALL.file + ".part").writeBytes(ByteArray(512))
        val state = store().states.value.getValue(SpeechModel.SMALL)
        assertEquals(SpeechModelState.Paused(512, body.size.toLong()), state)
        assertEquals(512f / body.size, state.fraction, 1e-6f)
    }

    @Test
    fun theBetterModelIsTheOneThatAnswersWhenBothAreThere() {
        val store = store()
        fetch(store, SpeechModel.BASE)
        assertEquals(SpeechModel.BASE, store.ready)
        fetch(store, SpeechModel.SMALL)
        assertEquals("small understands better, so it is the one used", SpeechModel.SMALL, store.ready)
    }

    @Test
    fun aModelAlreadyOnThePhoneIsNotFetchedAgain() {
        val store = store()
        fetch(store)
        val requests = server.requests
        store.download(SpeechModel.BASE)
        assertEquals("nothing was asked for a second time", requests, server.requests)
    }

    @Test
    fun aFileThatIsLongerThanTheModelStartsAgainRatherThanResuming() {
        File(directory, SpeechModel.BASE.file + ".part").writeBytes(ByteArray(body.size + 100))
        val store = store()
        assertEquals(SpeechModelState.Ready(body.size.toLong()), fetch(store))
        assertTrue("the range asked for the whole file", server.lastRange.isEmpty())
    }

    /** One request at a time, with ranges, an optional early hang-up and an optional status. */
    private class RangeServer(var body: ByteArray) {
        private val socket = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
        val port: Int get() = socket.localPort

        /** How many bytes to send before hanging up; 0 sends the whole body. */
        var cutAfter = 0

        /** Whether to answer 200 with the whole file even when a range was asked for. */
        var ignoreRange = false

        /** The status to answer with; anything but 200 has no body. */
        var status = 200

        var lastRange = ""
            private set
        var requests = 0
            private set

        private val thread = Thread {
            while (!socket.isClosed) {
                val client = try { socket.accept() } catch (e: IOException) { break }
                runCatching { serve(client) }
            }
        }.apply { isDaemon = true }

        fun start() = thread.start()
        fun stop() = socket.close()

        private fun serve(client: Socket) = client.use { connection ->
            val input = BufferedInputStream(connection.getInputStream())
            readLine(input) ?: return
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                headers[line.substringBefore(':').trim().lowercase()] = line.substringAfter(':').trim()
            }
            requests++
            lastRange = headers["range"].orEmpty()
            val out = connection.getOutputStream()
            if (status != 200) {
                out.write("HTTP/1.1 $status Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                out.flush()
                return
            }
            val from = if (ignoreRange) 0 else lastRange.removePrefix("bytes=").substringBefore('-').toIntOrNull() ?: 0
            val slice = body.copyOfRange(from.coerceIn(0, body.size), body.size)
            val head = if (from > 0 && !ignoreRange) {
                "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes $from-${body.size - 1}/${body.size}\r\nContent-Length: ${slice.size}\r\nConnection: close\r\n\r\n"
            } else {
                "HTTP/1.1 200 OK\r\nContent-Length: ${slice.size}\r\nConnection: close\r\n\r\n"
            }
            out.write(head.toByteArray())
            val sent = if (cutAfter > 0) slice.copyOfRange(0, cutAfter.coerceAtMost(slice.size)) else slice
            out.write(sent)
            out.flush()
        }

        private fun readLine(input: InputStream): String? {
            val line = StringBuilder()
            while (true) {
                val byte = input.read()
                if (byte < 0) return if (line.isEmpty()) null else line.toString()
                if (byte == '\n'.code) return line.toString()
                if (byte != '\r'.code) line.append(byte.toChar())
            }
        }
    }
}
