package com.unixcision.uniconnect.android.domain

import kotlinx.coroutines.flow.Flow

/** Raw PTY traffic from one attached tmux client on the host. */
sealed interface PtyEvent {
    data class Output(val bytes: ByteArray) : PtyEvent

    /**
     * The host reported the geometry of the attached window.
     *
     * [presentationColumns]/[presentationRows] is the canvas needed to present it, status rows
     * included; [sourceColumns]/[sourceRows] is the window itself. Matching the client's PTY to the
     * presentation size is what stops tmux from padding the extra rows.
     */
    data class Geometry(
        val presentationColumns: Int,
        val presentationRows: Int,
        val sourceColumns: Int,
        val sourceRows: Int,
    ) : PtyEvent

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
