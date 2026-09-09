package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.FileSender
import com.unixcision.uniconnect.android.domain.UploadFailure
import com.unixcision.uniconnect.android.domain.UploadLink
import com.unixcision.uniconnect.android.domain.UploadService
import com.unixcision.uniconnect.android.domain.UploadStyle
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID
import kotlin.coroutines.coroutineContext

/**
 * Sends a file with the platform's own [HttpURLConnection]: no new dependency, streaming with a
 * known length so nothing is buffered in memory, progress per chunk, and one link out.
 *
 * Every transport problem becomes an [UploadFailure] the screen can word; the request itself
 * follows the [UploadStyle] the service was measured with.
 */
class HttpFileSender(
    private val userAgent: String = "UniConnect Android",
    private val connectTimeoutMillis: Int = 30_000,
    private val readTimeoutMillis: Int = 600_000,
) : FileSender {
    override suspend fun send(service: UploadService, name: String, size: Long, open: () -> InputStream, onProgress: (Long) -> Unit): String = withContext(Dispatchers.IO) {
        val body = RequestBody.of(service.style, name, size)
        val connection = try {
            URL(service.uploadUrl(name)).openConnection() as HttpURLConnection
        } catch (e: IOException) {
            throw UploadFailure.Unreachable(service.domain)
        }
        try {
            connection.connectTimeout = connectTimeoutMillis
            connection.readTimeout = readTimeoutMillis
            connection.requestMethod = "POST"
            connection.doOutput = true
            connection.useCaches = false
            connection.setRequestProperty("User-Agent", userAgent)
            connection.setRequestProperty("Accept", "text/plain, application/json;q=0.9, */*;q=0.8")
            connection.setRequestProperty("Content-Type", body.contentType)
            connection.setFixedLengthStreamingMode(body.prefix.size + size + body.suffix.size)
            val input = try { open() } catch (e: Exception) { throw UploadFailure.Unreadable(name) }
            try {
                connection.outputStream.use { out ->
                    out.write(body.prefix)
                    input.use { copy(it, out, size, name, onProgress) }
                    out.write(body.suffix)
                }
            } catch (e: IOException) {
                throw UploadFailure.Unreachable(service.domain)
            }
            val code = try { connection.responseCode } catch (e: IOException) { throw UploadFailure.Unreachable(service.domain) }
            if (code >= 400) throw UploadFailure.Rejected(service.domain, code)
            val answer = try {
                connection.inputStream.use { it.readNBytes(MAX_ANSWER).toString(Charsets.UTF_8) }
            } catch (e: IOException) {
                throw UploadFailure.Unreachable(service.domain)
            }
            UploadLink.extract(answer) ?: throw UploadFailure.NoLink(service.domain)
        } finally {
            connection.disconnect()
        }
    }

    /** Copies exactly [size] bytes, reporting progress; fewer bytes means the file changed under us. */
    private suspend fun copy(input: InputStream, out: OutputStream, size: Long, name: String, onProgress: (Long) -> Unit) {
        val buffer = ByteArray(CHUNK)
        var sent = 0L
        while (sent < size) {
            coroutineContext.ensureActive()
            val read = try { input.read(buffer, 0, minOf(buffer.size.toLong(), size - sent).toInt()) } catch (e: IOException) { throw UploadFailure.Unreadable(name) }
            if (read < 0) throw UploadFailure.Unreadable(name)
            out.write(buffer, 0, read)
            sent += read
            onProgress(sent)
        }
    }

    /** What surrounds the file bytes for a style: nothing for a raw body, form boundaries otherwise. */
    private class RequestBody(val contentType: String, val prefix: ByteArray, val suffix: ByteArray) {
        companion object {
            fun of(style: UploadStyle, name: String, size: Long): RequestBody = when (style) {
                UploadStyle.RAW_NAMED -> RequestBody("application/octet-stream", ByteArray(0), ByteArray(0))
                UploadStyle.MULTIPART_FILE -> multipart(name, emptyList(), "file")
                UploadStyle.LITTERBOX -> multipart(name, listOf("reqtype" to "fileupload", "time" to "72h"), "fileToUpload")
            }.also { check(size >= 0) { "a file has a size" } }

            private fun multipart(name: String, fields: List<Pair<String, String>>, fileField: String): RequestBody {
                val boundary = "----UniConnect${UUID.randomUUID().toString().replace("-", "")}"
                val head = StringBuilder()
                fields.forEach { (field, value) ->
                    head.append("--").append(boundary).append("\r\n")
                        .append("Content-Disposition: form-data; name=\"").append(field).append("\"\r\n\r\n")
                        .append(value).append("\r\n")
                }
                head.append("--").append(boundary).append("\r\n")
                    .append("Content-Disposition: form-data; name=\"").append(fileField).append("\"; filename=\"").append(name.replace("\"", "_")).append("\"\r\n")
                    .append("Content-Type: application/octet-stream\r\n\r\n")
                val tail = "\r\n--$boundary--\r\n"
                return RequestBody("multipart/form-data; boundary=$boundary", head.toString().toByteArray(Charsets.UTF_8), tail.toByteArray(Charsets.UTF_8))
            }
        }
    }

    private companion object {
        const val CHUNK = 64 * 1024
        /** A link fits in far less; a huge answer is not one worth reading into memory. */
        const val MAX_ANSWER = 64 * 1024
    }
}
