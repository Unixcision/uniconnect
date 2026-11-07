package com.unixcision.uniconnect.android.domain

/**
 * One text sent from the composer, kept so it is never lost to a send that did not arrive or a
 * window that hung: it can be pasted again from the history.
 */
data class SentMessage(
    val id: String,
    /** When it was sent, in epoch milliseconds. */
    val createdAt: Long,
    /** Exactly what was written in the composer, before any terminal encoding. */
    val text: String,
    /** Whether Return went with it. */
    val withEnter: Boolean,
    val state: State,
    val machineName: String?,
    val windowName: String?,
) {
    enum class State {
        /** On its way; no answer yet. */
        SENDING,

        /** The machine took it. */
        DELIVERED,

        /** The machine did not take it. */
        FAILED,

        /** The app died before knowing: it may or may not have arrived. */
        UNCONFIRMED,
    }
}
