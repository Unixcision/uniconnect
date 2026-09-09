package com.unixcision.uniconnect.android.domain

/**
 * Records the voice for a machine-side transcription. Everything platform-specific (MediaRecorder,
 * the cache directory, the encoder) lives behind this, so the dictation that drives it is pure
 * enough to be tested without a microphone.
 */
interface VoiceRecorder {
    /** Whether the phone can record at all; without it there is nothing to send to the machine. */
    val available: Boolean

    /** Starts a fresh recording; false when the recorder could not be prepared. */
    fun start(): Boolean

    /** The loudness since the previous call, from 0 to 1, for the meter. */
    fun level(): Float

    /** Ends the recording and hands over what was captured, or null when nothing usable was. */
    fun stop(): AudioClip?

    /** Ends the recording and throws it away. */
    fun discard()
}
