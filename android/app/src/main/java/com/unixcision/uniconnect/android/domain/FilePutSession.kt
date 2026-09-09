package com.unixcision.uniconnect.android.domain

/**
 * One open connection to a host that implements `file_put.v1`: the four RPCs of the contract,
 * in the order a transfer uses them. A session is obtained from [FilePutClient] and is only
 * valid inside the block that received it.
 */
interface FilePutSession {
    /** `mobile.file.begin`: announces a file and gets the transfer id and the chunk size the host wants. */
    suspend fun begin(workspaceID: String, terminalID: String?, name: String, size: Long, mime: String?): FilePutTicket

    /** `mobile.file.chunk`: sends chunk [index] (consecutive from 0) and returns the bytes the host holds so far. */
    suspend fun chunk(transferID: String, index: Int, data: ByteArray): Long

    /** `mobile.file.commit`: closes the transfer with the hex SHA-256 of the whole file and learns where it landed. */
    suspend fun commit(transferID: String, sha256: String): FilePutOutcome

    /** `mobile.file.abort`: drops a transfer that will not be finished. */
    suspend fun abort(transferID: String)
}
