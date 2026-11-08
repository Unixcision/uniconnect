package com.unixcision.uniconnect.android.domain

import java.text.Normalizer

/**
 * The history's search box, for dictations and sent messages alike.
 *
 * Every word typed has to be found, in any order, in the text or in where it went (machine,
 * window), as loosely as a phone needs: no case, no accents (dictated Spanish arrives with
 * whatever accents the engine chose and nobody types them back), no punctuation, pieces of words,
 * and one typo in a word of four letters or more (two from eight letters on). Short words have to
 * be right, or «vpn» would find «vps». The closest comes first: whole words before pieces, pieces
 * before typos, and the words together as typed above all; ties keep the history's order, newest
 * first.
 */
object DictationSearch {
    fun matches(record: DictationRecord, query: String): Boolean = score(fieldsOf(record), query) != null

    /** A sent message matches on its text, its machine or its window. */
    fun matches(message: SentMessage, query: String): Boolean = score(fieldsOf(message), query) != null

    /** The dictations that match [query], closest first. */
    fun rankDictations(records: List<DictationRecord>, query: String): List<DictationRecord> = rank(records, query, ::fieldsOf)

    /** The sent messages that match [query], closest first. */
    fun rankMessages(messages: List<SentMessage>, query: String): List<SentMessage> = rank(messages, query, ::fieldsOf)

    private fun fieldsOf(record: DictationRecord) = listOf(record.text, record.machineName)

    private fun fieldsOf(message: SentMessage) = listOf(message.text, message.machineName, message.windowName)

    private fun <T> rank(items: List<T>, query: String, fields: (T) -> List<String?>): List<T> =
        items.mapNotNull { item -> score(fields(item), query)?.let { item to it } }
            .sortedByDescending { it.second }
            .map { it.first }

    /** How close [fields] are to [query]; null when some word is not there at all. */
    private fun score(fields: List<String?>, query: String): Int? {
        val words = fold(query).split(' ').filter { it.isNotEmpty() }
        if (words.isEmpty()) return 0
        val haystack = fold(fields.filterNotNull().joinToString(" "))
        val tokens = haystack.split(' ').filter { it.isNotEmpty() }.toSet()
        var total = 0
        for (word in words) {
            total += when {
                word in tokens -> WHOLE_WORD
                tokens.any { it.startsWith(word) } -> START_OF_WORD
                word in haystack -> INSIDE_A_WORD
                nearlyThere(word, tokens) -> WITH_A_TYPO
                else -> return null
            }
        }
        if (words.size > 1 && words.joinToString(" ") in haystack) total += TOGETHER_AS_TYPED
        return total
    }

    /** Whether [word] is one typo (two from eight letters) away from a word, or from its start. */
    private fun nearlyThere(word: String, tokens: Set<String>): Boolean {
        if (word.length < 4) return false
        val allowed = if (word.length >= 8) 2 else 1
        return tokens.any { token ->
            distance(word, token) <= allowed || (token.length > word.length && distance(word, token.take(word.length)) <= allowed)
        }
    }

    /** Edits between [a] and [b], a swap of two neighbouring letters counting as one (OSA). */
    private fun distance(a: String, b: String): Int {
        if (kotlin.math.abs(a.length - b.length) > 2) return Int.MAX_VALUE
        val d = Array(a.length + 1) { IntArray(b.length + 1) }
        for (i in 0..a.length) d[i][0] = i
        for (j in 0..b.length) d[0][j] = j
        for (i in 1..a.length) for (j in 1..b.length) {
            val cost = if (a[i - 1] == b[j - 1]) 0 else 1
            d[i][j] = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if (i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1]) d[i][j] = minOf(d[i][j], d[i - 2][j - 2] + 1)
        }
        return d[a.length][b.length]
    }

    /** Lower case, accents removed, anything but letters and digits turned into one space. */
    private fun fold(text: String): String =
        Normalizer.normalize(text.lowercase(), Normalizer.Form.NFD)
            .replace(Regex("\\p{Mn}+"), "")
            .replace(Regex("[^\\p{L}\\p{N}]+"), " ")
            .trim()

    private const val WHOLE_WORD = 4
    private const val START_OF_WORD = 3
    private const val INSIDE_A_WORD = 2
    private const val WITH_A_TYPO = 1
    private const val TOGETHER_AS_TYPED = 5
}
