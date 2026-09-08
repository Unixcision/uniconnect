package com.unixcision.uniconnect.android.domain

/**
 * The wheel steps still owed to the attached terminal, with a sign for direction.
 *
 * Steps are sent one by one with a small gap so tmux reads each as its own event. Queuing every
 * request behind the previous one let a flick with inertia pile up hundreds of steps that kept
 * scrolling for many seconds after the finger left the screen. This keeps a single balance
 * instead: requests in the same direction add up to a cap, a request in the other direction
 * cancels what was pending, and there is never more than about a second of scrolling in flight.
 */
class WheelBudget(private val cap: Int = DEFAULT_CAP) {
    /** Positive means up (older lines), negative means down. */
    var pending: Int = 0
        private set

    /** Adds a request; opposite directions cancel out, and the balance never exceeds [cap]. */
    fun add(up: Boolean, steps: Int) {
        val delta = if (up) steps else -steps
        val opposite = (pending > 0 && delta < 0) || (pending < 0 && delta > 0)
        pending = if (opposite) delta else (pending + delta).coerceIn(-cap, cap)
    }

    /** Takes one step to send, or null when nothing is owed. */
    fun next(): Boolean? = when {
        pending > 0 -> { pending -= 1; true }
        pending < 0 -> { pending += 1; false }
        else -> null
    }

    fun clear() { pending = 0 }

    companion object {
        /** About a second of steps at the gap used between them. */
        const val DEFAULT_CAP = 45
    }
}
