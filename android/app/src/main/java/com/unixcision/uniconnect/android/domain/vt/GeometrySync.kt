package com.unixcision.uniconnect.android.domain.vt

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Carries out [GeometryFollower]'s decisions for one attachment: the emulator takes a new size at
 * once and the host PTY right after, over the network.
 *
 * The two must end up equal. tmux draws its status line and sets its scroll region for the size
 * of the PTY; if the emulator has another size, every line feed scrolls the whole screen, status
 * line included, and the screen fills with copies of it. tmux reports the same geometry several
 * times in a row (window resized, client resized, option set), so a repeated report must never
 * cancel a PTY resize that is still on its way: it only drops a deferred one. A newer size does
 * supersede an older one still in flight.
 */
class GeometrySync(
    private val scope: CoroutineScope,
    private val follower: GeometryFollower,
    /** The size the emulator draws now. */
    private val canvas: () -> Pair<Int, Int>,
    /** Resizes the emulator (and shows the new frame). */
    private val resizeCanvas: (Int, Int) -> Unit,
    /** Resizes the host PTY; suspends while the request travels. */
    private val resizeHost: suspend (Int, Int) -> Unit,
    private val now: () -> Long = System::nanoTime,
) {
    private var hostResize: Job? = null
    private var deferred: Job? = null

    /** A geometry report from the host. */
    fun onReport(columns: Int, rows: Int) {
        // The newest report replaces whatever was deferred (the follower already forgot it).
        deferred?.cancel()
        deferred = null
        val (currentColumns, currentRows) = canvas()
        when (val decision = follower.onReport(columns, rows, currentColumns, currentRows, now())) {
            is GeometryFollower.Decision.Apply -> apply(decision.columns, decision.rows)
            is GeometryFollower.Decision.Defer -> deferred = scope.launch {
                // Bounded, intended delay: after the burst window there is, by definition, no burst.
                delay(decision.afterNanos / 1_000_000 + 1)
                val (laterColumns, laterRows) = canvas()
                val later = follower.onDeadline(laterColumns, laterRows, now())
                if (later is GeometryFollower.Decision.Apply) apply(later.columns, later.rows)
            }
            // Already this size: a PTY resize to it may still be travelling, and it must arrive.
            GeometryFollower.Decision.Ignore -> Unit
        }
    }

    private fun apply(columns: Int, rows: Int) {
        resizeCanvas(columns, rows)
        hostResize?.cancel()
        hostResize = scope.launch { runCatching { resizeHost(columns, rows) } }
    }

    /** Ends this attachment's geometry work. */
    fun stop() {
        deferred?.cancel()
        hostResize?.cancel()
        follower.reset()
    }
}
