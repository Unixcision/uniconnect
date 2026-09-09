package com.unixcision.uniconnect.android.domain

/** Opens a `file_put.v1` session to a machine over the private connection the app already uses. */
interface FilePutClient {
    /** Runs [block] with one session to [machine]; the connection closes when the block returns. */
    suspend fun <T> withSession(machine: Machine, block: suspend (FilePutSession) -> T): T
}
