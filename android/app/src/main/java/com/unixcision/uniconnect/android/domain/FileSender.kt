package com.unixcision.uniconnect.android.domain

import java.io.InputStream

/** Sends one file to a transfer service and returns the download link it answered with. */
interface FileSender {
    /**
     * Uploads [size] bytes read from a stream [open] gives, as [name], to [service].
     *
     * [onProgress] is called with the bytes sent so far, from the sending thread. Cancelling the
     * calling coroutine aborts the transfer. Throws an [UploadFailure] when there is no link.
     */
    suspend fun send(service: UploadService, name: String, size: Long, open: () -> InputStream, onProgress: (Long) -> Unit): String
}
