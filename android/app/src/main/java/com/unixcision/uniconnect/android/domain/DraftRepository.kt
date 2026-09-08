package com.unixcision.uniconnect.android.domain

/**
 * What the reader has typed in a window's composer and not yet sent.
 *
 * Kept per window and on disk: leaving the app, a re-attach or a killed process must not throw
 * away half a message. Only sending it or emptying the box forgets it.
 */
interface DraftRepository {
    suspend fun load(machineID: String, windowID: String): String
    suspend fun save(machineID: String, windowID: String, text: String)
}
