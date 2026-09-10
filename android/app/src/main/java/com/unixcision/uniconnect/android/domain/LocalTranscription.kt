package com.unixcision.uniconnect.android.domain

/**
 * Whisper running on this phone. Everything about the native library is behind this, so the
 * dictation that drives it is exercised in tests with no model, no JNI and no microphone.
 *
 * The engine is asked for one recording at a time. A run that is cancelled returns null rather
 * than half a sentence, and the native context is released whatever happens.
 */
interface LocalTranscription {
    /** Whether the native engine can run on this phone at all. */
    val available: Boolean

    /**
     * Turns [samples] (16 kHz mono, -1 to 1) into text using the model at [modelPath].
     *
     * - Parameter language: the two-letter code, or null to let the model decide.
     * - Parameter progress: told how far along the run is, and asked whether to stop.
     * - Returns: what was understood, or null when the run was cancelled.
     * - Throws: [LocalTranscriptionFailed] when the model or the engine could not run.
     */
    suspend fun transcribe(samples: FloatArray, modelPath: String, language: String?, progress: TranscriptionProgress?): Transcript?
}

/** How a running transcription talks to whoever asked for it. */
interface TranscriptionProgress {
    /** How far along the model is, from 0 to 100. */
    fun onProgress(percent: Int)

    /** Whether the run should stop now. */
    fun cancelled(): Boolean
}

/** The engine on the phone could not turn a recording into text. */
class LocalTranscriptionFailed(message: String) : Exception(message)
