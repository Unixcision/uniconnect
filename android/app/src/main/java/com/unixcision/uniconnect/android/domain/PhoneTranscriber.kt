package com.unixcision.uniconnect.android.domain

/**
 * Whisper on this phone, for transcribing a kept recording again without any machine: for when
 * the machines are out of reach, or to compare.
 */
interface PhoneTranscriber {
    /** Whether it can run now: the engine loads and a model is downloaded. */
    val ready: Boolean

    /**
     * What Whisper understands from [audio] (the AAC the recorder writes).
     *
     * - Throws: [LocalTranscriptionFailed] or [AudioDecodeFailed] when it could not be read.
     */
    suspend fun transcribe(audio: ByteArray, language: String?): String
}
