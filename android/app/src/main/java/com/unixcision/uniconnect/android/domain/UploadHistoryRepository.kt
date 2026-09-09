package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

/** The last links obtained, newest first, kept on the phone so they can be copied again later. */
interface UploadHistoryRepository {
    val history: Flow<List<UploadResult>>

    /** Puts [result] first and drops anything past [LIMIT]. */
    suspend fun add(result: UploadResult)

    /** Forgets every entry with [link]. */
    suspend fun remove(link: String)

    companion object {
        /** How many links are kept. */
        const val LIMIT = 30
    }
}
