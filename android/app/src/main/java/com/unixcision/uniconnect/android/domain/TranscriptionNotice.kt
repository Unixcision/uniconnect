package com.unixcision.uniconnect.android.domain

/**
 * A line the composer shows when the engine that ran was not the one that was asked for.
 *
 * [repeats] tells the screen whether the line is worth saying again: a fact about the machines is
 * said once, while a machine that cannot do what the reader explicitly asked for is said every
 * time it happens.
 */
enum class TranscriptionNotice(val repeats: Boolean) {
    /** Automatic: nothing better could run, so the phone's own recogniser dictates. */
    HOST_CANNOT(repeats = false),

    /** The machine the reader picked is not there or cannot transcribe, so the automatic rule ran. */
    CHOSEN_UNAVAILABLE(repeats = false),

    /** "Whisper on the phone" was chosen with no model downloaded, so the automatic rule ran. */
    LOCAL_UNAVAILABLE(repeats = false),

    /** Whisper on the phone broke mid-recording and a machine took the recording instead. */
    LOCAL_FAILED_HANDED_OVER(repeats = false),
}
