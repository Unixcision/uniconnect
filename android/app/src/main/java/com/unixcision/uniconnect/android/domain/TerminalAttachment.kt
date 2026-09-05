package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

/** Raw PTY traffic from one attached tmux client on the host. */
sealed interface PtyEvent {
    data class Output(val bytes: ByteArray) : PtyEvent
    /** The attached client exited (session gone, host detached, or process died). */
    data object Exit : PtyEvent
}

/**
 * One live attachment to a window's tmux session. Bytes flow both ways over the same
 * authorized connection; closing it detaches the phone's client and never the session.
 */
interface TerminalAttachment : AutoCloseable {
    val attachID: String
    val columns: Int
    val rows: Int
    val events: Flow<PtyEvent>
    suspend fun send(bytes: ByteArray)
    suspend fun resize(columns: Int, rows: Int)
}
