package com.unixcision.uniconnect.android.domain

/** A complete desktop render grid, never a guessed reconstruction from a partial output tail. */
data class TerminalSnapshot(
    val columns: Int, val rows: Int, val spans: List<Span>,
    val foreground: String?, val background: String?, val cursor: Cursor?,
    val revision: ULong? = null,
    /** History lines above the screen; spans use rows `0 until scrollbackRows`. Empty on hosts that do not export it. */
    val scrollbackRows: Int = 0,
    val scrollbackSpans: List<Span> = emptyList(),
) {
    // Styles are frozen per span: frame-local style IDs may be reused in a later delta.
    data class Span(val row: Int, val column: Int, val text: String, val cellWidth: Int, val style: Style)
    data class Style(val foreground: String? = null, val background: String? = null, val bold: Boolean = false,
        val italic: Boolean = false, val inverse: Boolean = false, val invisible: Boolean = false,
        val underline: Boolean = false, val faint: Boolean = false, val strikethrough: Boolean = false,
        val overline: Boolean = false)
    data class Cursor(val row: Int, val column: Int, val visible: Boolean)
}
