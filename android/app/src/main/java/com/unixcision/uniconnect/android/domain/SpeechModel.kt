package com.unixcision.uniconnect.android.domain

/**
 * A Whisper model the phone can hold, as published by the whisper.cpp project.
 *
 * Nothing is bundled in the app: a model is downloaded when the reader asks for one and lives in
 * the app's own storage, so uninstalling takes it with it. The two on offer are the ones worth
 * having on a phone; the tiny ones are not better than the system recogniser and the big ones do
 * not finish in a reasonable time on any phone.
 *
 * - Parameter file: the name the model has on disk and on the server.
 * - Parameter bytes: its exact size, which is what a finished download is checked against.
 */
enum class SpeechModel(val file: String, val bytes: Long) {
    /** Around 57 MiB. Understands whole sentences well and reads a minute of speech in seconds. */
    BASE("ggml-base-q5_1.bin", 59_707_625),

    /** Around 181 MiB. Clearly better with names and long sentences, and clearly slower. */
    SMALL("ggml-small-q5_1.bin", 190_085_487);

    /** Where the file is fetched from. */
    val url: String get() = "$HOST$file"

    companion object {
        /** The whisper.cpp model repository; the only address the app downloads a model from. */
        const val HOST = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/"

        /** The first four bytes of every ggml model file, checked before one is called usable. */
        val MAGIC = byteArrayOf(0x67, 0x67, 0x6d, 0x6c)

        /** Reads a stored name; anything unrecognised is nothing at all rather than a guess. */
        fun named(raw: String?): SpeechModel? = entries.firstOrNull { it.name == raw }

        /**
         * The one to use out of those that are [ready], preferring the better model.
         *
         * Order is by quality, not by what was downloaded last: someone who keeps both wants the
         * small model to be the one that answers.
         */
        fun best(ready: Set<SpeechModel>): SpeechModel? = entries.reversed().firstOrNull { it in ready }
    }
}
