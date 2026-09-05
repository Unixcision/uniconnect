package com.unixcision.uniconnect.android.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalFrameDecoderTest {
    @Test fun sharedLinuxFixturePreservesWideCellsColorsInverseAndRevision() {
        // Shared with Linux test_mobile_render_grid.py: truecolor, wide glyph, DEC line drawing.
        val json = JSONObject("""
            {"format":"cmux.render-grid.v1","surface_id":"00000000-0000-4000-8000-000000000042",
             "state_seq":42,"revision":42,"columns":12,"rows":2,"full":true,
             "active_screen":"primary","cleared_rows":[],"terminal_foreground":"#e6edff",
             "terminal_background":"#020a33","cursor":{"row":1,"column":3,"visible":true},
             "styles":[{"id":0},{"id":1,"foreground":"#0be4fa","bold":true},
               {"id":2,"foreground":"#0be4fa","bold":true,"inverse":true}],
             "row_spans":[{"row":0,"column":0,"style_id":1,"text":"Hola ","cell_width":5},
               {"row":0,"column":5,"style_id":2,"text":"界","cell_width":2},
               {"row":1,"column":0,"style_id":0,"text":"┌─┐","cell_width":3}]}
        """.trimIndent())
        val frame = TerminalFrameDecoder().decode(json, "00000000-0000-4000-8000-000000000042")
        val snapshot = frame.snapshot
        assertTrue(frame.full)
        assertEquals(42uL, snapshot.revision)
        assertEquals("#020a33", snapshot.background)
        assertEquals(listOf("Hola ", "界", "┌─┐"), snapshot.spans.map { it.text })
        assertEquals(2, snapshot.spans[1].cellWidth)
        assertTrue(snapshot.spans[1].style.inverse)
        assertEquals("#0be4fa", snapshot.spans[1].style.foreground)
        assertEquals(3, snapshot.cursor?.column)
        assertEquals(1, snapshot.cursor?.row)
    }
}
