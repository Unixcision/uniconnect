package com.unixcision.uniconnect.android.domain

/** Validates a terminal input receipt independently of the transport and UI. */
object TerminalInputReceipt {
    fun accepts(expected: TerminalTarget, actual: TerminalTarget, queued: Boolean?): Boolean =
        queued == true && expected.workspaceID.equals(actual.workspaceID, ignoreCase = true) &&
            expected.windowID.equals(actual.windowID, ignoreCase = true)
}
