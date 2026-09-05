package com.unixcision.uniconnect.android.domain.vt

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalEmulatorTest {
    private fun term(cols: Int = 20, rows: Int = 5) = TerminalEmulator(cols, rows)
    private fun TerminalEmulator.row(r: Int) = screen.rowText(r)
    private fun TerminalEmulator.cursor() = screen.cursorRow to screen.cursorCol

    @Test
    fun printsWrapsAndScrollsLikeATerminal() {
        val t = term(5, 2)
        t.feed("abcdefg\r\nxyz")
        assertEquals("fg", t.row(0))
        assertEquals("xyz", t.row(1))
        assertEquals(1 to 3, t.cursor())
    }

    @Test
    fun cursorMovementAndAbsolutePositioning() {
        val t = term()
        t.feed("[3;4Hx")
        assertEquals(2 to 4, t.cursor())
        t.feed("[2A[10D")
        assertEquals(0 to 0, t.cursor())
        t.feed("[99;99H")
        assertEquals(4 to 19, t.cursor())
        t.feed("[2G")
        assertEquals(4 to 1, t.cursor())
    }

    @Test
    fun eraseAndInsertDelete() {
        val t = term(10, 3)
        t.feed("hello world[1;3H[K")
        assertEquals("he", t.row(0))
        t.feed("[2J")
        assertEquals("", t.row(0)); assertEquals("", t.row(1))
        t.feed("[Habcdef[1;2H[2P")
        assertEquals("adef", t.row(0))
        t.feed("[1;2H[2@")
        assertEquals("a  def", t.row(0))
        t.feed("[2;1Hline2[1;1H[L")
        assertEquals("", t.row(0)); assertEquals("a  def", t.row(1)); assertEquals("line2", t.row(2))
    }

    @Test
    fun scrollRegionKeepsLinesOutsideIt() {
        val t = term(10, 4)
        t.feed("top\r\nA\r\nB\r\nbottom")
        t.feed("[2;3r[3;1H\nNEW")
        assertEquals("top", t.row(0))
        assertEquals("B", t.row(1))
        assertEquals("NEW", t.row(2))
        assertEquals("bottom", t.row(3))
    }

    @Test
    fun sgrColorsAndAttributesReachTheSnapshot() {
        val t = term(30, 1)
        t.feed("[1;31mred[0m [38;5;46mgreen[m [48:2::10:20:30mbg[m")
        val spans = t.snapshot().spans
        assertEquals("red", spans[0].text); assertTrue(spans[0].style.bold); assertEquals("#cd0000", spans[0].style.foreground)
        assertEquals("green", spans[1].text); assertEquals("#00ff00", spans[1].style.foreground)
        assertEquals("bg", spans[2].text); assertEquals("#0a141e", spans[2].style.background)
        assertFalse(spans[2].style.bold)
    }

    @Test
    fun alternateScreenRestoresMainContent() {
        val t = term(10, 2)
        t.feed("main[?1049h")
        assertEquals("", t.row(0))
        t.feed("alt")
        assertEquals("alt", t.row(0))
        t.feed("[?1049l")
        assertEquals("main", t.row(0))
        assertEquals(0 to 4, t.cursor())
    }

    @Test
    fun wideAndCombiningCharactersOccupyCorrectCells() {
        val t = term(6, 1)
        t.feed("a漢b")
        val spans = t.snapshot().spans
        assertEquals(listOf("a漢b"), spans.map { it.text })
        assertEquals(4, spans[0].cellWidth)
        assertEquals(0 to 4, t.cursor())
        t.feed("é")
        assertEquals("a漢bé", t.row(0))
        assertEquals(0 to 5, t.cursor())
    }

    @Test
    fun utf8SplitAcrossChunksDecodes() {
        val t = term(6, 1)
        val bytes = "ñ€".toByteArray()
        t.feed(bytes.copyOfRange(0, 1)); t.feed(bytes.copyOfRange(1, bytes.size))
        assertEquals("ñ€", t.row(0))
    }

    @Test
    fun modesAndResponses() {
        val t = term()
        t.feed("[?1h[?1000h[?1006h[?2004h[?25l")
        assertTrue(t.applicationCursorKeys); assertTrue(t.mouseReporting); assertTrue(t.bracketedPaste)
        assertFalse(t.snapshot().cursor!!.visible)
        assertEquals("[<64;3;2M", t.encodeWheel(up = true, column = 2, row = 1))
        assertEquals("[200~x[201~", t.encodePaste("x"))
        t.feed("[?1000l")
        assertNull(t.encodeWheel(true, 0, 0))
        t.feed("[2;3H[6n[c")
        assertEquals("[2;3R[?62;22c", t.drainResponses())
        assertEquals("", t.drainResponses())
    }

    @Test
    fun titleLineDrawingAndUnknownSequencesAreHarmless() {
        val t = term(10, 1)
        t.feed("]0;hola(0lqk(B[?9999hP junk \\ok")
        assertEquals("hola", t.title)
        assertEquals("┌─┐ok", t.row(0))
    }

    @Test
    fun resizeKeepsContentAndClampsCursor() {
        val t = term(10, 3)
        t.feed("abcdefghij[3;10H")
        t.resize(5, 2)
        assertEquals("abcde", t.row(0))
        assertEquals(1 to 4, t.cursor())
    }
}
