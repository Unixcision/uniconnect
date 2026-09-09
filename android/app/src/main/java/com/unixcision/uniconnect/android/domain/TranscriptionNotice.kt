package com.unixcision.uniconnect.android.domain

/**
 * A line the composer shows when the engine that ran was not the one that was asked for.
 *
 * [repeats] tells the screen whether the line is worth saying again: a fact about the machines is
 * said once, while a machine that cannot do what the reader explicitly asked for is said every
 * time it happens.
 */
enum class TranscriptionNotice(val repeats: Boolean) {
    /** Automatic: no machine can transcribe, so the phone dictates. */
    HOST_CANNOT(repeats = false),

    /** "Always on the machine of the window" was chosen, but that machine cannot transcribe. */
    HOST_REQUIRED_UNAVAILABLE(repeats = true),

    /** The machine the reader picked is not there or cannot transcribe, so the automatic rule ran. */
    CHOSEN_UNAVAILABLE(repeats = false),
}
