package com.unixcision.uniconnect.android.domain.vt

/**
 * Decides how a client follows the window geometry a host reports.
 *
 * Resizing the client can make the host recompute and report again, so obeying every report can
 * loop. Rate, not value, separates that loop from a person resizing the desktop window: nothing is
 * vetoed because it was seen before, and a size dropped during a burst is applied when the burst
 * ends. Every new report replaces whatever was pending, including a report that matches the canvas.
 *
 * Pure and clock-injected, so the races are unit-tested without waiting.
 */
class GeometryFollower(
    private val maxPerWindow: Int = 5,
    private val windowNanos: Long = 3_000_000_000L,
) {
    /** What the caller should do with a report or with a deadline that fired. */
    sealed interface Decision {
        /** Resize the emulator and the host PTY to this size. */
        data class Apply(val columns: Int, val rows: Int) : Decision
        /** Nothing now; wake up after [afterNanos] and call [onDeadline]. */
        data class Defer(val afterNanos: Long) : Decision
        /** Nothing to do. */
        data object Ignore : Decision
    }

    private val applied = ArrayDeque<Long>()
    private var pending: Pair<Int, Int>? = null

    /** A report from the host, with the size the client currently draws. */
    fun onReport(columns: Int, rows: Int, currentColumns: Int, currentRows: Int, nowNanos: Long): Decision {
        // The newest report is the only truth: it replaces any pending target, even when it merely
        // confirms the current canvas, which is what makes a stale deferred size impossible.
        pending = null
        if (columns == currentColumns && rows == currentRows) return Decision.Ignore
        trim(nowNanos)
        if (applied.size < maxPerWindow) {
            applied.addLast(nowNanos)
            return Decision.Apply(columns, rows)
        }
        pending = columns to rows
        val oldest = applied.firstOrNull() ?: nowNanos
        return Decision.Defer((windowNanos - (nowNanos - oldest)).coerceAtLeast(1))
    }

    /** The deferred wake-up fired; returns the pending size when it is still needed. */
    fun onDeadline(currentColumns: Int, currentRows: Int, nowNanos: Long): Decision {
        val wanted = pending ?: return Decision.Ignore
        pending = null
        if (wanted.first == currentColumns && wanted.second == currentRows) return Decision.Ignore
        // The burst is over by construction; start counting again from this application.
        applied.clear()
        applied.addLast(nowNanos)
        return Decision.Apply(wanted.first, wanted.second)
    }

    /** Forgets history and any pending target; used when an attachment starts or ends. */
    fun reset() {
        applied.clear()
        pending = null
    }

    private fun trim(nowNanos: Long) {
        while (applied.isNotEmpty() && nowNanos - applied.first() > windowNanos) applied.removeFirst()
    }
}
