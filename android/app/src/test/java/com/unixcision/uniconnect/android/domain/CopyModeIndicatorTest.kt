package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A pane left in tmux's copy mode ignores everything typed at it, so the phone offers a way out
 * only while tmux is drawing its position indicator. Recognising that indicator is what decides
 * whether a window looks dead or merely paused.
 */
class CopyModeIndicatorTest {
    private val plain = TerminalSnapshot.Style()

    private fun snapshot(vararg spans: TerminalSnapshot.Span) = TerminalSnapshot(
        columns = 80, rows = 24, spans = spans.toList(),
        foreground = null, background = null, cursor = null,
    )

    private fun span(row: Int, column: Int, text: String) =
        TerminalSnapshot.Span(row, column, text, text.length, plain)

    @Test
    fun theIndicatorOnTheTopRowMeansCopyMode() {
        assertTrue(snapshot(span(0, 68, "[1013/1013]")).inCopyMode)
        assertTrue(snapshot(span(0, 74, "[0/342]")).inCopyMode)
        // Drawn beside other content on the same row, which is how tmux renders it over a pane.
        assertTrue(snapshot(span(0, 0, "return version_id"), span(0, 70, "[12/900]")).inCopyMode)
    }

    @Test
    fun aLiveScreenIsNotCopyMode() {
        assertFalse(snapshot().inCopyMode)
        assertFalse(snapshot(span(0, 0, "Ask Codex to do anything")).inCopyMode)
        // Shapes that look close but are not a position: no digits, or only one side of the slash.
        assertFalse(snapshot(span(0, 60, "[master]")).inCopyMode)
        assertFalse(snapshot(span(0, 60, "[12/]")).inCopyMode)
        assertFalse(snapshot(span(0, 60, "[/900]")).inCopyMode)
    }

    @Test
    fun theSameShapeLowerDownIsJustOutput() {
        // Only the pane's top row carries the indicator; a program printing "[3/4]" mid-screen is
        // output, and treating it as copy mode would offer an exit from a window that is fine.
        assertFalse(snapshot(span(7, 4, "step [3/4] done")).inCopyMode)
        assertFalse(snapshot(span(23, 0, "[1013/1013]")).inCopyMode)
    }
}
