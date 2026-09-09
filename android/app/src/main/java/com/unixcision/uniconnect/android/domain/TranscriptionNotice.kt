package com.unixcision.uniconnect.android.domain

/**
 * A line the composer shows when the chosen engine was not the one that ran.
 *
 * [repeats] tells the screen whether the line is worth saying again: the automatic fallback is a
 * fact about the machine and is said once, while a machine that cannot do what the reader
 * explicitly asked for is said every time it happens.
 */
enum class TranscriptionNotice(val repeats: Boolean) {
    /** Automatic: the machine does not announce `transcribe.v1`, so the phone dictates. */
    HOST_CANNOT(repeats = false),

    /** "Always on the machine" was chosen, but this machine cannot transcribe. */
    HOST_REQUIRED_UNAVAILABLE(repeats = true),
}
