package com.unixcision.uniconnect.android.domain

/**
 * Which try of a dictation is the live one, so a callback from an abandoned try cannot speak for
 * the one the reader is in.
 *
 * A recogniser answers whenever it wants. Between an engine giving up and the retry that was
 * queued for it, the reader may have cancelled, or left the screen, or started again; without this
 * the queued retry would open the microphone after a cancel, and a late result would land in a
 * dictation that no longer exists.
 *
 * Every try takes a number from [begin] and carries it into everything it schedules; anything that
 * arrives when [isLive] says otherwise is dropped. [abandon] is what a cancel does: it makes every
 * try that is already in flight stale without needing to reach any of them.
 *
 * Not thread safe on purpose: it belongs to whatever runs the recogniser, which on Android is the
 * main thread and nowhere else.
 */
class DictationAttempts {
    private var current = 0

    /** Starts a new try and gives it its number. */
    fun begin(): Int = ++current

    /** Whether [attempt] is still the one that matters; nothing is live before the first one. */
    fun isLive(attempt: Int): Boolean = current != 0 && attempt == current

    /** Leaves every try in flight behind, so nothing pending can act any more. */
    fun abandon() { current++ }
}
