package com.unixcision.uniconnect.android.domain

/** An ok response acknowledges both immediate delivery (queued=false) and deferred delivery (true). */
object TerminalInputReceipt {
    fun accepts(expected: TerminalTarget, actual: TerminalTarget, queued: Boolean?): Boolean =
        queued != null && expected.workspaceID.equals(actual.workspaceID, ignoreCase = true) &&
            expected.windowID.equals(actual.windowID, ignoreCase = true)
}
