package com.unixcision.uniconnect.android.domain

/** Why a dictation ended without text, in terms the screen can word. */
enum class DictationFailure {
    NO_PERMISSION,
    NO_NETWORK,
    NOT_UNDERSTOOD,
    ENGINE_UNAVAILABLE,
    BUSY,
    OTHER,

    /** Nothing was captured: the recorder gave no file, or an empty one. */
    NO_AUDIO,

    /**
     * The phone's recogniser gave up before a word could have been said, on the on-device engine
     * and on the network one. It is the engine that is not answering, not the voice.
     */
    RECOGNISER_SILENT,

    /** The machine refused the recording for being too long or too big. */
    TOO_LONG,

    /** UniConnect is locked on the machine. */
    HOST_LOCKED,

    /** The machine is already transcribing as much as it can; the recording waits for a retry. */
    HOST_BUSY,

    /** The machine has no transcription engine after all; the phone takes over. */
    HOST_UNSUPPORTED,

    /** The machine took the recording and could not turn it into text. */
    HOST_FAILED,

    /** The recording never reached the machine. */
    HOST_UNREACHABLE,
}

/** Where a dictation is, from the composer's point of view. */
sealed class DictationState {
    /** Nothing is being recorded. */
    data object Idle : DictationState()

    /**
     * Recording: [partial] is what has been understood so far, [level] the voice level from 0 to 1.
     *
     * [recording] tells the bar that the audio is going to a machine, so there is no partial text
     * to show and [seconds] is the length captured so far.
     */
    data class Listening(
        val partial: String = "",
        val level: Float = 0f,
        val seconds: Int = 0,
        val recording: Boolean = false,
    ) : DictationState()

    /** The recording is on its way to the machine; [cut] when it was stopped at the five-minute limit. */
    data class Transcribing(val cut: Boolean = false) : DictationState()

    /** Recording ended with [text] understood; the composer takes it once and resets. */
    data class Done(val text: String) : DictationState()

    /** Recording ended with nothing usable; the composer shows [reason] once and offers [retry]. */
    data class Failed(val reason: DictationFailure, val retry: DictationRetry = DictationRetry.NONE) : DictationState()
}
