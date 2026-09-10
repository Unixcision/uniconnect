package com.unixcision.uniconnect.android.domain

/**
 * A line the composer shows when the engine that ran was not the one that was asked for.
 *
 * [repeats] tells the screen whether the line is worth saying again. A fact about the machines
 * under the automatic rule is said once, because the rule is working as it was described. An
 * explicit choice that could not be honoured is said **every single time**: someone comparing
 * engines has to know, on every dictation, that what they ordered did not run. Saying it once and
 * then quietly using something else for the next ten dictations is the silence this avoids.
 */
enum class TranscriptionNotice(val repeats: Boolean) {
    /** Automatic: nothing better could run, so the phone's own recogniser dictates. */
    HOST_CANNOT(repeats = false),

    /** The machine the reader picked is not there or cannot transcribe, so something else ran. */
    CHOSEN_UNAVAILABLE(repeats = true),

    /** "Whisper on the phone" was chosen with no model downloaded, so something else ran. */
    LOCAL_UNAVAILABLE(repeats = true),

    /** Whisper on the phone broke after recording and a machine took the recording instead. */
    LOCAL_FAILED_HANDED_OVER(repeats = true),
}
