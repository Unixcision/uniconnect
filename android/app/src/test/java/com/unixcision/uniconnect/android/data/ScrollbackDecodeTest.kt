package com.unixcision.uniconnect.android.data

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ScrollbackDecodeTest {
    private fun grid(full: Boolean, scrollbackRows: Int) = JSONObject("""
        {"format":"cmux.render-grid.v1","surface_id":"w1","columns":10,"rows":2,"full":$full,
         "styles":[{"id":1,"bold":true}],
         "row_spans":[{"row":0,"column":0,"text":"now","style_id":1}],
         "scrollback_rows":$scrollbackRows,
         "scrollback_spans":[{"row":0,"column":0,"text":"old"},{"row":${scrollbackRows - 1},"column":2,"text":"er"}]}
    """)

    @Test
    fun fullFrameCarriesHistoryAboveTheScreen() {
        val frame = TerminalFrameDecoder().decode(grid(full = true, scrollbackRows = 3), "w1")
        assertEquals(3, frame.snapshot.scrollbackRows)
        assertEquals(listOf("old", "er"), frame.snapshot.scrollbackSpans.map { it.text })
        assertEquals(2, frame.snapshot.scrollbackSpans.last().row)
        assertTrue(frame.snapshot.spans.single().style.bold)
    }

    @Test
    fun deltaFrameKeepsThePreviousHistory() {
        val decoder = TerminalFrameDecoder()
        val first = decoder.decode(grid(full = true, scrollbackRows = 3), "w1").applyingTo(null)
        val delta = decoder.decode(grid(full = false, scrollbackRows = 3), "w1")
        assertEquals(0, delta.snapshot.scrollbackRows)
        val merged = delta.applyingTo(first)
        assertEquals(3, merged.scrollbackRows)
        assertEquals(2, merged.scrollbackSpans.size)
    }
}
