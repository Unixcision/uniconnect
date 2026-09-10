package com.unixcision.uniconnect.android.domain

/**
 * The one recogniser a dictation is using, held so that a cleanup queued by an old try cannot take
 * away the one a newer try has already put in its place.
 *
 * Tearing a recogniser down has to happen on the main thread and is therefore posted, which means
 * it runs later than it was decided. Between those two moments a dictation may have started again
 * and created another engine; a cleanup that simply emptied "the current one" would destroy the
 * live engine and leave the reader with a bar and no microphone. Every release names the engine it
 * meant, and only that one is let go.
 *
 * The slot compares by identity, never by value, because two engines are never interchangeable.
 * Not thread safe on purpose: it belongs to whatever runs the recogniser, which on Android is the
 * main thread and nowhere else.
 */
class RecogniserSlot<Engine : Any> {
    private var held: Engine? = null

    /** What the slot holds right now, if anything. */
    val engine: Engine? get() = held

    /** Puts [engine] in the slot and gives back what it replaced, which is the caller's to destroy. */
    fun replace(engine: Engine): Engine? {
        val previous = held
        held = engine
        return previous
    }

    /** Empties the slot and gives back what was in it. */
    fun clear(): Engine? {
        val previous = held
        held = null
        return previous
    }

    /**
     * Empties the slot only when it still holds [engine], and says whether it did. A cleanup that
     * arrives late finds another engine there and leaves it alone.
     */
    fun releaseIfHeld(engine: Engine): Boolean {
        if (held !== engine) return false
        held = null
        return true
    }
}
