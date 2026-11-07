package com.unixcision.uniconnect.android.domain

import java.text.Normalizer

/**
 * The history's search box: every word typed must appear in the dictation's text or in its
 * machine's name, ignoring case and accents, because dictated Spanish arrives with whatever
 * accents the engine chose and nobody types them back on a phone.
 */
object DictationSearch {
    fun matches(record: DictationRecord, query: String): Boolean = matches(listOf(record.text, record.machineName), query)

    /** A sent message matches on its text, its machine or its window. */
    fun matches(message: SentMessage, query: String): Boolean =
        matches(listOf(message.text, message.machineName, message.windowName), query)

    private fun matches(fields: List<String?>, query: String): Boolean {
        val words = fold(query).split(' ').filter { it.isNotBlank() }
        if (words.isEmpty()) return true
        val haystack = fold(fields.filterNotNull().joinToString(" "))
        return words.all { it in haystack }
    }

    /** Lower case, accents removed, any whitespace collapsed to one space. */
    private fun fold(text: String): String =
        Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
            .replace(Regex("\\s+"), " ")
}
