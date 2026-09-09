package com.unixcision.uniconnect.android.domain

import java.io.InputStream
import java.security.MessageDigest

/**
 * Drives one `file_put.v1` transfer over a [FilePutSession]: begin, the file cut into the chunk
 * size the host asked for (never above the contract's 1 MiB), consecutive indices from zero, the
 * SHA-256 of everything sent, and commit. Anything that goes wrong after begin aborts the
 * transfer on the host before the error reaches the caller.
 *
 * Pure apart from the session: a fake session and a byte array exercise every rule in a test.
 */
object FilePutTransfer {
    /** The contract's ceiling for one chunk; a host asking for more is cut down to it. */
    const val MAX_CHUNK_BYTES = 1024 * 1024

    /** The contract's ceiling for one file; checked before anything is sent. */
    const val MAX_SIZE_BYTES = 200L * 1024 * 1024

    /**
     * Sends [size] bytes read from [open] as [name] into [workspaceID] (and [terminalID] when the
     * file belongs to a window), reporting the bytes sent so far through [onProgress].
     *
     * Throws [MachineFailure.Rejected] with the host's code, `too_large` when the file exceeds the
     * contract before begin, or [UploadFailure.Unreadable] when the file cannot be read.
     */
    suspend fun run(
        session: FilePutSession,
        workspaceID: String,
        terminalID: String?,
        name: String,
        size: Long,
        mime: String?,
        open: () -> InputStream,
        onProgress: (Long) -> Unit,
    ): FilePutOutcome {
        if (size > MAX_SIZE_BYTES) throw MachineFailure.Rejected("too_large", "el archivo supera los 200 MiB del contrato")
        val ticket = session.begin(workspaceID, terminalID, name, size, mime)
        val chunkBytes = ticket.chunkBytes.coerceIn(1, MAX_CHUNK_BYTES)
        try {
            val digest = MessageDigest.getInstance("SHA-256")
            val input = try { open() } catch (e: Exception) { throw UploadFailure.Unreadable(name) }
            input.use { stream ->
                val buffer = ByteArray(chunkBytes)
                var index = 0
                var sent = 0L
                while (sent < size) {
                    val wanted = minOf(chunkBytes.toLong(), size - sent).toInt()
                    var got = 0
                    while (got < wanted) {
                        val read = try { stream.read(buffer, got, wanted - got) } catch (e: Exception) { throw UploadFailure.Unreadable(name) }
                        if (read < 0) throw UploadFailure.Unreadable(name)
                        got += read
                    }
                    val data = buffer.copyOf(got)
                    digest.update(data)
                    session.chunk(ticket.transferID, index, data)
                    index++
                    sent += got
                    onProgress(sent)
                }
            }
            return session.commit(ticket.transferID, hex(digest.digest()))
        } catch (e: Throwable) {
            runCatching { session.abort(ticket.transferID) }
            throw e
        }
    }

    /** Lower-case hex of [bytes], the form the contract wants the checksum in. */
    fun hex(bytes: ByteArray): String = bytes.joinToString("") { "%02x".format(it) }
}
