package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.UploadFailure
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.domain.UploadStyle
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.BufferedInputStream
import java.io.ByteArrayInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket

/**
 * The sender against a local server that plays each measured service: what it receives, what
 * it answers, and how every way of failing is reported.
 *
 * The server is a few lines over a [ServerSocket]: Android unit tests compile against
 * `android.jar`, which has no `com.sun.net.httpserver`, and the sender only needs plain HTTP/1.1.
 */
class HttpFileSenderTest {
    private lateinit var server: TinyHttpServer
    private var method = ""
    private var path = ""
    private var contentType = ""
    private var userAgent = ""
    private var received = ByteArray(0)
    private val sender = HttpFileSender()
    private val payload = ByteArray(200_000) { (it % 251).toByte() }

    @Before
    fun start() {
        server = TinyHttpServer { request ->
            method = request.method
            path = request.path
            contentType = request.headers["content-type"].orEmpty()
            userAgent = request.headers["user-agent"].orEmpty()
            received = request.body
            when {
                path == "/rechazo.bin" -> 500 to "boom"
                path == "/silencio.bin" -> 200 to "ok"
                path == "/json.bin" -> 200 to """{"url":"http://127.0.0.1:${server.port}/j/json.bin"}"""
                path == "/upload" -> 200 to "http://127.0.0.1:${server.port}/t/notas.txt"
                path == "/resources/internals/api.php" -> 200 to "https://litter.catbox.moe/abc123.txt"
                else -> 200 to "wget http://127.0.0.1:${server.port}/s$path\n"
            }
        }
        server.start()
    }

    @After
    fun stop() { server.stop() }

    private fun service(style: UploadStyle) = UploadService("http://127.0.0.1:${server.port}", style)

    private fun send(style: UploadStyle, name: String, bytes: ByteArray = payload, onProgress: (Long) -> Unit = {}): String = runBlocking {
        sender.send(service(style), name, bytes.size.toLong(), { ByteArrayInputStream(bytes) }, onProgress)
    }

    @Test
    fun rawNamedPostsTheBytesToTheNameAndReadsTheWgetLine() {
        val link = send(UploadStyle.RAW_NAMED, "notas.txt")
        assertEquals("POST", method)
        assertEquals("/notas.txt", path)
        assertEquals("application/octet-stream", contentType)
        assertEquals("UniConnect Android", userAgent)
        assertArrayEquals(payload, received)
        assertEquals("http://127.0.0.1:${server.port}/s/notas.txt", link)
    }

    @Test
    fun multipartFilePostsOneFileFieldToUpload() {
        val link = send(UploadStyle.MULTIPART_FILE, "notas.txt")
        assertEquals("/upload", path)
        assertTrue(contentType.startsWith("multipart/form-data; boundary="))
        val boundary = contentType.substringAfter("boundary=")
        val text = received.toString(Charsets.ISO_8859_1)
        assertTrue(text.contains("Content-Disposition: form-data; name=\"file\"; filename=\"notas.txt\""))
        assertTrue(text.startsWith("--$boundary\r\n"))
        assertTrue(text.endsWith("\r\n--$boundary--\r\n"))
        val body = text.substringAfter("\r\n\r\n").substringBeforeLast("\r\n--$boundary--\r\n")
        assertArrayEquals(payload, body.toByteArray(Charsets.ISO_8859_1))
        assertEquals("http://127.0.0.1:${server.port}/t/notas.txt", link)
    }

    @Test
    fun litterboxSendsItsThreeFields() {
        val link = send(UploadStyle.LITTERBOX, "notas.txt", "hola".toByteArray())
        assertEquals("/resources/internals/api.php", path)
        val text = received.toString(Charsets.ISO_8859_1)
        assertTrue(text.contains("name=\"reqtype\"\r\n\r\nfileupload\r\n"))
        assertTrue(text.contains("name=\"time\"\r\n\r\n72h\r\n"))
        assertTrue(text.contains("name=\"fileToUpload\"; filename=\"notas.txt\""))
        assertTrue(text.contains("\r\n\r\nhola\r\n"))
        assertEquals("https://litter.catbox.moe/abc123.txt", link)
    }

    @Test
    fun progressCountsUpToTheFileSize() {
        val seen = mutableListOf<Long>()
        send(UploadStyle.RAW_NAMED, "grande.bin") { seen.add(it) }
        assertTrue(seen.isNotEmpty())
        assertEquals(payload.size.toLong(), seen.last())
        assertEquals(seen.sorted(), seen)
    }

    @Test
    fun aJsonAnswerGivesItsLink() {
        assertEquals("http://127.0.0.1:${server.port}/j/json.bin", send(UploadStyle.RAW_NAMED, "json.bin", "x".toByteArray()))
    }

    @Test
    fun anErrorStatusIsRejectedWithItsCode() {
        try {
            send(UploadStyle.RAW_NAMED, "rechazo.bin", "x".toByteArray())
            fail("expected a rejection")
        } catch (e: UploadFailure.Rejected) {
            assertEquals(500, e.code)
            assertEquals("http://127.0.0.1:${server.port}", e.domain)
        }
    }

    @Test
    fun anAnswerWithoutALinkIsAFailure() {
        try {
            send(UploadStyle.RAW_NAMED, "silencio.bin", "x".toByteArray())
            fail("expected no link")
        } catch (e: UploadFailure.NoLink) {
            assertEquals("http://127.0.0.1:${server.port}", e.domain)
        }
    }

    @Test
    fun aHostThatDoesNotAnswerIsUnreachable() {
        val port = server.port
        server.stop()
        try {
            runBlocking { sender.send(UploadService("http://127.0.0.1:$port", UploadStyle.RAW_NAMED), "x.bin", 1, { ByteArrayInputStream(byteArrayOf(1)) }) {} }
            fail("expected unreachable")
        } catch (e: UploadFailure.Unreachable) {
            assertEquals("http://127.0.0.1:$port", e.domain)
        }
    }

    @Test
    fun aFileThatCannotBeOpenedIsUnreadable() {
        try {
            runBlocking { sender.send(service(UploadStyle.RAW_NAMED), "roto.bin", 4, { throw IllegalStateException("gone") }) {} }
            fail("expected unreadable")
        } catch (e: UploadFailure.Unreadable) {
            assertEquals("roto.bin", e.name)
        }
    }

    /** One request at a time over plain HTTP/1.1 on the loopback interface; enough to play a transfer service. */
    private class TinyHttpServer(private val handler: (Request) -> Pair<Int, String>) {
        class Request(val method: String, val path: String, val headers: Map<String, String>, val body: ByteArray)

        private val socket = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
        val port: Int get() = socket.localPort
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
            val requestLine = readLine(input) ?: return
            val parts = requestLine.split(' ')
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = readLine(input) ?: break
                if (line.isEmpty()) break
                headers[line.substringBefore(':').trim().lowercase()] = line.substringAfter(':').trim()
            }
            val length = headers["content-length"]?.toIntOrNull() ?: 0
            val body = ByteArray(length)
            var offset = 0
            while (offset < length) {
                val read = input.read(body, offset, length - offset)
                if (read < 0) break
                offset += read
            }
            val (code, text) = handler(Request(parts[0], parts.getOrElse(1) { "/" }, headers, body))
            val bytes = text.toByteArray()
            val out = connection.getOutputStream()
            out.write("HTTP/1.1 $code ${if (code >= 400) "Error" else "OK"}\r\nContent-Type: text/plain\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n\r\n".toByteArray())
            out.write(bytes)
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
