package com.unixcision.uniconnect.android.domain

/**
 * How an attachment's path or link lands in the composer: appended to what is already typed with
 * one space between, quoted when it carries a space so the agent reads it as one path.
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
}
