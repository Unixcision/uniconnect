package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.TerminalFrame
import com.unixcision.uniconnect.android.domain.TerminalSnapshot
import org.json.JSONArray
import org.json.JSONObject

/** Strictly validates the host grid before any sizes or text reach the native drawing surface. */
class TerminalFrameDecoder {
    fun decode(grid: JSONObject, expectedWindowID: String): TerminalFrame {
        require(grid.optString("format") == "cmux.render-grid.v1")
        require(grid.getString("surface_id").equals(expectedWindowID, ignoreCase = true))
        val columns = grid.getInt("columns").also { require(it in 1..1000) }
        val rows = grid.getInt("rows").also { require(it in 1..1000) }
        val styles = (grid.optJSONArray("styles") ?: JSONArray()).objects().associate { style ->
            style.getInt("id") to TerminalSnapshot.Style(
                foreground = style.optionalString("foreground"), background = style.optionalString("background"),
                bold = style.optBoolean("bold"), italic = style.optBoolean("italic"), inverse = style.optBoolean("inverse"),
                invisible = style.optBoolean("invisible"), underline = style.optBoolean("underline"),
                faint = style.optBoolean("faint"), strikethrough = style.optBoolean("strikethrough"), overline = style.optBoolean("overline"),
            )
        }
        val spans = grid.getJSONArray("row_spans").objects().map { span ->
            val row = span.getInt("row").also { require(it in 0 until rows) }
            val column = span.getInt("column").also { require(it in 0 until columns) }
            val text = span.getString("text")
            require(text.none { it.isISOControl() })
            val width = span.optInt("cell_width", text.codePointCount(0, text.length)).also { require(it in 0..(columns - column)) }
            TerminalSnapshot.Span(row, column, text, width, styles[span.optInt("style_id", 0)] ?: TerminalSnapshot.Style())
        }
        val cursor = grid.optJSONObject("cursor")?.let {
            TerminalSnapshot.Cursor(it.getInt("row"), it.getInt("column"), it.optBoolean("visible", true))
        }
        val revision = grid.opt("revision")?.takeUnless { it == JSONObject.NULL }?.toString()?.toULongOrNull()
        val snapshot = TerminalSnapshot(columns, rows, spans, grid.optionalString("terminal_foreground"), grid.optionalString("terminal_background"), cursor, revision)
        val cleared = grid.optJSONArray("cleared_rows")?.let { array ->
            List(array.length()) { array.getInt(it).also { row -> require(row in 0 until rows) } }.toSet()
        } ?: emptySet()
        return TerminalFrame(snapshot, grid.optBoolean("full", true), cleared)
    }

    private fun JSONArray.objects() = List(length()) { getJSONObject(it) }
    private fun JSONObject.optionalString(key: String): String? = if (isNull(key) || !has(key)) null else getString(key)
}
