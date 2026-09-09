package com.unixcision.uniconnect.android.domain

/** The language dictation is recognised in: the phone's own, or one fixed by the reader. */
enum class DictationLanguage(val tag: String?) {
    /** Whatever the phone is set to. */
    DEVICE(null),
    ES_ES("es-ES"),
    EN_US("en-US");

    /** The two-letter code `mobile.audio.transcribe` takes, or null to let the machine decide. */
    val code: String? get() = tag?.substringBefore('-')

    /**
     * The tag to ask the phone's recogniser for: the fixed one, or the phone's own when the reader
     * left it to the device. Naming it is not the same as leaving it out: some engines fall back to
     * English when they are asked for nothing, so the device's own tag travels explicitly. An empty
     * tag is never sent.
     *
     * ```kotlin
     * DictationLanguage.DEVICE.recognitionTag(Locale.getDefault().toLanguageTag())
     * ```
     */
    fun recognitionTag(deviceTag: String): String? = (tag ?: deviceTag).takeIf { it.isNotBlank() }

    companion object {
        /** Reads a stored name, falling back to [DEVICE] for anything unrecognised. */
        fun named(raw: String?): DictationLanguage = entries.firstOrNull { it.name == raw } ?: DEVICE
    }
}
