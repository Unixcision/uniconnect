package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class TerminalFrameTest {
    private val red = TerminalSnapshot.Style(foreground = "#ff0000")
    private val blue = TerminalSnapshot.Style(foreground = "#0000ff")
    private fun line(row: Int, text: String, style: TerminalSnapshot.Style = red) = TerminalSnapshot.Span(row, 0, text, text.length, style)
    private fun screen(vararg spans: TerminalSnapshot.Span, revision: ULong? = null) = TerminalSnapshot(80, 24, spans.toList(), "#ffffff", "#000000", null, revision)

    @Test fun fullSnapshotReplacesAllPreviousRows() {
        val old = screen(line(0, "anterior"), line(1, "ya no existe"))
        val next = screen(line(0, "nuevo"))
        assertEquals(next, TerminalFrame(next, true, emptySet()).applyingTo(old))
    }

    @Test fun deltaClearsWholeAffectedRowsWithoutRecoloringUntouchedRows() {
        val old = screen(line(0, "rojo"), line(1, "borrar"), line(2, "sustituir"))
        val patch = TerminalFrame(screen(line(2, "azul", blue)), false, setOf(1))
        val actual = patch.applyingTo(old)
        assertEquals(listOf(line(0, "rojo"), line(2, "azul", blue)), actual.spans)
        assertEquals(red, actual.spans.first().style)
    }

    @Test fun deltaCannotInventABaselineOrResizeAnUnknownGrid() {
        val patch = TerminalFrame(screen(line(0, "nuevo")), false, emptySet())
        assertThrows(TerminalFrame.FullReplayRequired::class.java) { patch.applyingTo(null) }
        assertThrows(TerminalFrame.FullReplayRequired::class.java) { patch.applyingTo(screen().copy(columns = 40)) }
    }

    @Test fun staleOrRepeatedVisualRevisionsNeverRollBackTheDisplay() {
        val current = screen(line(0, "actual"), revision = 15u)
        assertEquals(current, TerminalFrame(screen(line(0, "viejo"), revision = 14u), true, emptySet()).applyingTo(current))
        assertEquals(current, TerminalFrame(screen(line(0, "repetido"), revision = 15u), true, emptySet()).applyingTo(current))
        val next = screen(line(0, "posterior"), revision = 16u)
        assertEquals(next, TerminalFrame(next, true, emptySet()).applyingTo(current))
    }
}
