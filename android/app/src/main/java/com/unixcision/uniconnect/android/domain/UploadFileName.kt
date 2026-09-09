package com.unixcision.uniconnect.android.domain

import java.text.Normalizer

/**
 * The name a file is sent under. Services put it in the URL and on disk, so it is reduced to a
 * safe leaf: no directories, no control or shell characters, accents folded to plain letters,
 * the extension kept, and never empty.
 */
object UploadFileName {
    private const val FALLBACK = "archivo"
    private const val MAX_LENGTH = 100
    private val unsafe = Regex("[^A-Za-z0-9._-]+")
    private val marks = Regex("\\p{M}+")

    /** [raw] as it will be sent. */
    fun sanitize(raw: String): String {
        val leaf = raw.trim().substringAfterLast('/').substringAfterLast('\\')
        val folded = Normalizer.normalize(leaf, Normalizer.Form.NFD).replace(marks, "")
        // An underscore left touching the extension dot (`c?.txt` -> `c_.txt`) is noise, not a name.
        val clean = folded.replace(unsafe, "_").replace(Regex("_+"), "_").replace(Regex("_\\.|\\._"), ".").trim('_', '.')
        if (clean.isEmpty()) return FALLBACK
        if (clean.length <= MAX_LENGTH) return clean
        val extension = clean.substringAfterLast('.', "")
        if (extension.isEmpty() || extension.length > 16) return clean.take(MAX_LENGTH)
        return clean.substringBeforeLast('.').take(MAX_LENGTH - extension.length - 1) + "." + extension
    }
}
