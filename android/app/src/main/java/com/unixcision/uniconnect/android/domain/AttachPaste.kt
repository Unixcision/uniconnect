package com.unixcision.uniconnect.android.domain

/**
 * How an attachment's path or link lands in the composer: appended to what is already typed with
 * one space between, quoted when it carries a space so the agent reads it as one path. And
 * whether it lands there on its own at all: only when the file sits where the window's agent
 * runs, which is the server for an SSH box and the host for a local one.
 */
object AttachPaste {
    /** [draft] with [reference] pasted at the end. */
    fun pasteInto(draft: String, reference: String): String {
        val token = if (reference.any { it.isWhitespace() }) "\"" + reference.replace("\"", "\\\"") + "\"" else reference
        return when {
            draft.isEmpty() -> token
            draft.last().isWhitespace() -> draft + token
            else -> "$draft $token"
        }
    }

    /**
     * Whether a file that ended at [location] may be pasted into a window whose box is SSH
     * ([windowIsSSH] true), local (false) or of unknown kind (null). A remote copy is always
     * where the agent can read it; a host copy is not, for an SSH window: the reader is told and
     * offered the path, but nothing is pasted for them.
     */
    fun shouldPaste(location: FilePutLocation, windowIsSSH: Boolean?): Boolean = when (location) {
        FilePutLocation.REMOTE -> true
        FilePutLocation.HOST -> windowIsSSH != true
    }
}
