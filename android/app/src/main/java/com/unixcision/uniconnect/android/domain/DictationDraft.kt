package com.unixcision.uniconnect.android.domain

/** How dictated text lands in the composer: after what is already typed, one space between, never over it. */
object DictationDraft {
    /** [draft] with [spoken] appended. */
    fun append(draft: String, spoken: String): String {
        val text = spoken.trim()
        if (text.isEmpty()) return draft
        if (draft.isBlank()) return text
        return draft.trimEnd() + " " + text
    }
}
