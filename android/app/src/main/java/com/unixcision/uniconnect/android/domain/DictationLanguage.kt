package com.unixcision.uniconnect.android.domain

/** The language dictation is recognised in: the phone's own, or one fixed by the reader. */
enum class DictationLanguage(val tag: String?) {
    /** Whatever the phone is set to. */
    DEVICE(null),
    ES_ES("es-ES"),
    EN_US("en-US");

    /** The two-letter code `mobile.audio.transcribe` takes, or null to let the machine decide. */
    val code: String? get() = tag?.substringBefore('-')

    companion object {
        /** Reads a stored name, falling back to [DEVICE] for anything unrecognised. */
        fun named(raw: String?): DictationLanguage = entries.firstOrNull { it.name == raw } ?: DEVICE
    }
}
