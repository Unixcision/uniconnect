package com.unixcision.uniconnect.android.domain.vt

import com.unixcision.uniconnect.android.domain.vt.GeometryFollower.Decision
import org.junit.Assert.assertEquals
import org.junit.Test

class GeometryFollowerTest {
    private val second = 1_000_000_000L
    private fun follower() = GeometryFollower(maxPerWindow = 5, windowNanos = 3 * second)

    @Test
    fun followsOrdinaryResizingForever() {
        val follower = follower()
        var now = 0L
        var columns = 80
        var rows = 24
        // One resize every ten seconds, far more than any per-attachment budget would allow.
        // Sizes start at 81 so every report is a real change; a report equal to the canvas is
        // covered by its own test, where the right answer is Ignore.
        repeat(20) { index ->
            now += 10 * second
            val wanted = 81 + index to 24
            val decision = follower.onReport(wanted.first, wanted.second, columns, rows, now)
            assertEquals(Decision.Apply(wanted.first, wanted.second), decision)
            columns = wanted.first; rows = wanted.second
        }
    }

    @Test
    fun goingBackToAnEarlierSizeIsAllowed() {
        val follower = follower()
        assertEquals(Decision.Apply(100, 30), follower.onReport(100, 30, 80, 24, second))
        assertEquals(Decision.Apply(80, 24), follower.onReport(80, 24, 100, 30, 2 * second))
        assertEquals(Decision.Apply(100, 30), follower.onReport(100, 30, 80, 24, 3 * second))
    }

    @Test
    fun aBurstIsPausedAndTheLastSizeApplied() {
        val follower = follower()
        var columns = 80
        var rows = 24
        repeat(5) { index ->
            val decision = follower.onReport(90 + index, 24, columns, rows, index.toLong())
            assertEquals(Decision.Apply(90 + index, 24), decision)
            columns = 90 + index
        }
        val deferred = follower.onReport(200, 50, columns, rows, 10)
        assertEquals(Decision.Defer::class, deferred::class)
        // Nothing is applied while the burst lasts; the wake-up applies the newest size.
        assertEquals(Decision.Apply(200, 50), follower.onDeadline(columns, rows, 4 * second))
        assertEquals(Decision.Ignore, follower.onDeadline(200, 50, 5 * second))
    }

    @Test
    fun aReportMatchingTheCanvasCancelsAStalePendingSize() {
        val follower = follower()
        repeat(5) { follower.onReport(90 + it, 24, 80, 24, it.toLong()) }
        assertEquals(Decision.Defer::class, follower.onReport(200, 50, 94, 24, 10)::class)
        // The host settles back on the size already drawn: the pending 200x50 must not survive.
        assertEquals(Decision.Ignore, follower.onReport(94, 24, 94, 24, 20))
        assertEquals(Decision.Ignore, follower.onDeadline(94, 24, 4 * second))
    }

    @Test
    fun anImmediateApplyReplacesAPendingSize() {
        val follower = follower()
        repeat(5) { follower.onReport(90 + it, 24, 80, 24, it.toLong()) }
        assertEquals(Decision.Defer::class, follower.onReport(200, 50, 94, 24, 10)::class)
        // Once the window has passed a new report applies at once, and the old pending is dropped.
        assertEquals(Decision.Apply(120, 40), follower.onReport(120, 40, 94, 24, 4 * second))
        assertEquals(Decision.Ignore, follower.onDeadline(120, 40, 5 * second))
    }

    @Test
    fun resetForgetsPendingWorkOnCloseOrReattach() {
        val follower = follower()
        repeat(5) { follower.onReport(90 + it, 24, 80, 24, it.toLong()) }
        assertEquals(Decision.Defer::class, follower.onReport(200, 50, 94, 24, 10)::class)
        follower.reset()
        assertEquals(Decision.Ignore, follower.onDeadline(94, 24, 4 * second))
        assertEquals(Decision.Apply(200, 50), follower.onReport(200, 50, 94, 24, 5 * second))
    }
}
