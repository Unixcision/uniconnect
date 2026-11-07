package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.StateFlow

/**
 * Every text sent from the composer, newest first, with whether it arrived.
 *
 * The composer records a text before sending it and settles it with the answer, so a send that
 * fails, a window that hangs or an app that dies on the way never costs what was written.
 */
interface SentMessageHistory {
    /** Newest first. */
    val messages: StateFlow<List<SentMessage>>

    /** Keeps [text] as being sent to [windowName] on [machineName]; returns its id. */
    fun record(text: String, withEnter: Boolean, machineName: String?, windowName: String?): String

    /** Whether the machine took message [id]. */
    fun settle(id: String, delivered: Boolean)

    /** Removes these messages. */
    fun delete(ids: Set<String>)

    /** Removes every message. */
    fun clear()

    companion object {
        /** How many messages are kept; older ones go first. A few thousand texts weigh little. */
        const val MAX_MESSAGES = 2_000
    }
}
