package com.unixcision.uniconnect.android.domain.vt

import com.unixcision.uniconnect.android.domain.TerminalSnapshot

/**
 * The visible screen of an xterm-compatible terminal: main and alternate buffers, cursor,
 * scroll region, tab stops, DEC private modes. Scrollback lives in tmux on the host, so this
 * buffer never grows beyond [rows]; it only needs to be as faithful as a tmux client.
 */
class VtScreen(columns: Int, rows: Int) {
    class Cell(var text: String = " ", var style: TerminalSnapshot.Style = DEFAULT_STYLE, var width: Int = 1) {
        fun reset(style: TerminalSnapshot.Style = DEFAULT_STYLE) { text = " "; this.style = style; width = 1 }
        fun copyFrom(other: Cell) { text = other.text; style = other.style; width = other.width }
    }

    var columns = columns.coerceIn(1, 1000); private set
    var rows = rows.coerceIn(1, 1000); private set
    private var main = newBuffer()
    private var alternate = newBuffer()
    private var lines = main
    val isAlternate: Boolean get() = lines === alternate

    var cursorRow = 0; private set
    var cursorCol = 0; private set
    var style = DEFAULT_STYLE
    var scrollTop = 0; private set
    var scrollBottom = this.rows - 1; private set
    var wrapPending = false; private set

    var autoWrap = true
    var originMode = false
    var insertMode = false
    var cursorVisible = true
    var applicationCursorKeys = false
    var applicationKeypad = false
    var bracketedPaste = false
    var lineFeedNewLine = false
    /** 0 = off, 1000 = clicks, 1002 = drag, 1003 = any motion. */
    var mouseMode = 0
    var mouseSgr = false
    var lineDrawing = false
    var title: String = ""

    private var tabStops = BooleanArray(this.columns) { it % 8 == 0 }
    private data class SavedCursor(val row: Int, val col: Int, val style: TerminalSnapshot.Style, val origin: Boolean, val wrap: Boolean, val lineDrawing: Boolean)
    private var savedMain: SavedCursor? = null
    private var savedAlternate: SavedCursor? = null

    private fun newBuffer() = Array(rows) { Array(columns) { Cell() } }

    // ---- cursor -------------------------------------------------------------------------

    fun moveTo(row: Int, col: Int) {
        val top = if (originMode) scrollTop else 0
        val bottom = if (originMode) scrollBottom else rows - 1
        cursorRow = (row + top).coerceIn(top, bottom)
        cursorCol = col.coerceIn(0, columns - 1)
        wrapPending = false
    }

    fun moveCursor(deltaRow: Int, deltaCol: Int) {
        val top = if (originMode) scrollTop else 0
        val bottom = if (originMode) scrollBottom else rows - 1
        cursorRow = (cursorRow + deltaRow).coerceIn(top, bottom)
        cursorCol = (cursorCol + deltaCol).coerceIn(0, columns - 1)
        wrapPending = false
    }

    fun setColumn(col: Int) { cursorCol = col.coerceIn(0, columns - 1); wrapPending = false }

    fun saveCursor() {
        val saved = SavedCursor(cursorRow, cursorCol, style, originMode, autoWrap, lineDrawing)
        if (isAlternate) savedAlternate = saved else savedMain = saved
    }

    fun restoreCursor() {
        val saved = (if (isAlternate) savedAlternate else savedMain) ?: SavedCursor(0, 0, DEFAULT_STYLE, false, true, false)
        cursorRow = saved.row.coerceIn(0, rows - 1); cursorCol = saved.col.coerceIn(0, columns - 1)
        style = saved.style; originMode = saved.origin; autoWrap = saved.wrap; lineDrawing = saved.lineDrawing
        wrapPending = false
    }

    // ---- printing -----------------------------------------------------------------------

    fun print(text: String, width: Int) {
        if (width == 0) {
            // Combining mark: attach to the previous cell.
            val col = (if (wrapPending) cursorCol else cursorCol - 1).coerceIn(0, columns - 1)
            val cell = lines[cursorRow][col]
            if (cell.width > 0) cell.text += text
            return
        }
        if (wrapPending) {
            if (autoWrap) { cursorCol = 0; lineFeed() }
            wrapPending = false
        }
        if (width == 2 && cursorCol == columns - 1) {
            // A wide glyph never straddles the margin: pad and wrap first.
            lines[cursorRow][cursorCol].reset(style)
            if (autoWrap) { cursorCol = 0; lineFeed() } else return
        }
        val line = lines[cursorRow]
        if (insertMode) {
            for (c in columns - 1 downTo cursorCol + width) line[c].copyFrom(line[c - width])
        }
        clearWideAt(line, cursorCol)
        line[cursorCol].also { it.text = text; it.style = style; it.width = width }
        if (width == 2) {
            clearWideAt(line, cursorCol + 1)
            line[cursorCol + 1].also { it.text = ""; it.style = style; it.width = 0 }
        }
        cursorCol += width
        if (cursorCol >= columns) { cursorCol = columns - 1; wrapPending = true }
    }

    /** Overwriting one half of a wide glyph blanks the other half, as real terminals do. */
    private fun clearWideAt(line: Array<Cell>, col: Int) {
        val cell = line[col]
        if (cell.width == 0 && col > 0) line[col - 1].reset(line[col - 1].style)
        if (cell.width == 2 && col + 1 < columns) line[col + 1].reset(line[col + 1].style)
    }

    fun carriageReturn() { cursorCol = 0; wrapPending = false }

    fun lineFeed() {
        wrapPending = false
        if (cursorRow == scrollBottom) scrollUp(1) else if (cursorRow < rows - 1) cursorRow++
        if (lineFeedNewLine) cursorCol = 0
    }

    fun reverseIndex() {
        wrapPending = false
        if (cursorRow == scrollTop) scrollDown(1) else if (cursorRow > 0) cursorRow--
    }

    fun backspace() { if (cursorCol > 0) cursorCol--; wrapPending = false }

    fun tab() {
        wrapPending = false
        var col = cursorCol + 1
        while (col < columns - 1 && !tabStops[col]) col++
        cursorCol = col.coerceAtMost(columns - 1)
    }

    fun backTab(count: Int) {
        repeat(count) {
            var col = cursorCol - 1
            while (col > 0 && !tabStops[col]) col--
            cursorCol = col.coerceAtLeast(0)
        }
        wrapPending = false
    }

    fun setTabStop() { tabStops[cursorCol] = true }
    fun clearTabStop(all: Boolean) { if (all) tabStops.fill(false) else tabStops[cursorCol] = false }

    // ---- scrolling and regions ----------------------------------------------------------

    fun setScrollRegion(top: Int, bottom: Int) {
        val t = top.coerceIn(0, rows - 1)
        val b = bottom.coerceIn(0, rows - 1)
        if (b <= t) { scrollTop = 0; scrollBottom = rows - 1 } else { scrollTop = t; scrollBottom = b }
        moveTo(0, 0)
    }

    fun scrollUp(count: Int) = scrollRegion(scrollTop, scrollBottom, count)
    fun scrollDown(count: Int) = scrollRegion(scrollTop, scrollBottom, -count)

    private fun scrollRegion(top: Int, bottom: Int, count: Int) {
        val n = count.coerceIn(-(bottom - top + 1), bottom - top + 1)
        if (n == 0) return
        if (n > 0) {
            for (r in top..bottom) {
                if (r + n <= bottom) lines[r] = lines[r + n].also { lines[r + n] = lines[r] } else lines[r].forEach { it.reset(blankStyle()) }
            }
        } else {
            val m = -n
            for (r in bottom downTo top) {
                if (r - m >= top) lines[r] = lines[r - m].also { lines[r - m] = lines[r] } else lines[r].forEach { it.reset(blankStyle()) }
            }
        }
    }

    fun insertLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        scrollRegion(cursorRow, scrollBottom, -count)
        wrapPending = false
    }

    fun deleteLines(count: Int) {
        if (cursorRow !in scrollTop..scrollBottom) return
        scrollRegion(cursorRow, scrollBottom, count)
        wrapPending = false
    }

    // ---- erasing ------------------------------------------------------------------------

    fun eraseInDisplay(mode: Int) {
        when (mode) {
            0 -> { eraseInLine(0); for (r in cursorRow + 1 until rows) blankLine(r) }
            1 -> { eraseInLine(1); for (r in 0 until cursorRow) blankLine(r) }
            2, 3 -> for (r in 0 until rows) blankLine(r)
        }
        wrapPending = false
    }

    fun eraseInLine(mode: Int) {
        val line = lines[cursorRow]
        val range = when (mode) { 0 -> cursorCol until columns; 1 -> 0..cursorCol; else -> 0 until columns }
        for (c in range) { clearWideAt(line, c); line[c].reset(blankStyle()) }
        wrapPending = false
    }

    fun eraseChars(count: Int) {
        val line = lines[cursorRow]
        for (c in cursorCol until (cursorCol + count).coerceAtMost(columns)) { clearWideAt(line, c); line[c].reset(blankStyle()) }
        wrapPending = false
    }

    fun insertChars(count: Int) {
        val line = lines[cursorRow]
        val n = count.coerceIn(1, columns - cursorCol)
        for (c in columns - 1 downTo cursorCol + n) line[c].copyFrom(line[c - n])
        for (c in cursorCol until cursorCol + n) line[c].reset(blankStyle())
        wrapPending = false
    }

    fun deleteChars(count: Int) {
        val line = lines[cursorRow]
        val n = count.coerceIn(1, columns - cursorCol)
        for (c in cursorCol until columns) if (c + n < columns) line[c].copyFrom(line[c + n]) else line[c].reset(blankStyle())
        wrapPending = false
    }

    private fun blankLine(row: Int) { lines[row].forEach { it.reset(blankStyle()) } }
    /** Erased cells keep the current background (BCE), never the text attributes. */
    private fun blankStyle() = if (style.background == null) DEFAULT_STYLE else TerminalSnapshot.Style(background = style.background)

    // ---- buffers ------------------------------------------------------------------------

    fun useAlternateScreen(enable: Boolean, clear: Boolean) {
        if (enable == isAlternate) return
        lines = if (enable) alternate else main
        if (enable && clear) for (r in 0 until rows) blankLine(r)
        wrapPending = false
    }

    fun reset() {
        main = newBuffer(); alternate = newBuffer(); lines = main
        cursorRow = 0; cursorCol = 0; style = DEFAULT_STYLE; scrollTop = 0; scrollBottom = rows - 1
        autoWrap = true; originMode = false; insertMode = false; cursorVisible = true
        applicationCursorKeys = false; applicationKeypad = false; bracketedPaste = false; lineFeedNewLine = false
        mouseMode = 0; mouseSgr = false; lineDrawing = false; wrapPending = false
        tabStops = BooleanArray(columns) { it % 8 == 0 }; savedMain = null; savedAlternate = null
    }

    fun resize(newColumns: Int, newRows: Int) {
        val cols = newColumns.coerceIn(1, 1000); val rws = newRows.coerceIn(1, 1000)
        if (cols == columns && rws == rows) return
        fun grow(buffer: Array<Array<Cell>>) = Array(rws) { r -> Array(cols) { c -> if (r < buffer.size && c < buffer[r].size) buffer[r][c] else Cell() } }
        val wasAlternate = isAlternate
        main = grow(main); alternate = grow(alternate); lines = if (wasAlternate) alternate else main
        columns = cols; rows = rws
        tabStops = BooleanArray(cols) { it % 8 == 0 }
        scrollTop = 0; scrollBottom = rws - 1
        cursorRow = cursorRow.coerceIn(0, rws - 1); cursorCol = cursorCol.coerceIn(0, cols - 1); wrapPending = false
    }

    // ---- reading ------------------------------------------------------------------------

    fun cell(row: Int, col: Int): Cell = lines[row][col]

    fun rowText(row: Int): String = buildString { lines[row].forEach { if (it.width > 0) append(it.text) } }.trimEnd()

    /** Groups equal-style runs into spans the existing grid renderer already understands. */
    fun snapshot(revision: ULong? = null): TerminalSnapshot {
        val spans = ArrayList<TerminalSnapshot.Span>()
        for (r in 0 until rows) {
            val line = lines[r]
            var c = 0
            while (c < columns) {
                val start = c
                val runStyle = line[c].style
                val text = StringBuilder()
                var cells = 0
                while (c < columns && line[c].style == runStyle) {
                    if (line[c].width > 0) { text.append(line[c].text); cells += line[c].width }
                    c++
                }
                val decorated = runStyle.background != null || runStyle.inverse || runStyle.underline || runStyle.strikethrough || runStyle.overline
                // An undecorated run that reaches the end of the line carries only padding after its
                // last glyph: dropping it keeps spans honest about what the terminal actually shows.
                if (!decorated && c == columns) {
                    val trimmed = text.toString().trimEnd(' ')
                    cells -= text.length - trimmed.length
                    text.setLength(0)
                    text.append(trimmed)
                }
                val blank = text.isBlank() && !decorated
                if (!blank && cells > 0) spans += TerminalSnapshot.Span(r, start, text.toString(), cells, runStyle)
            }
        }
        return TerminalSnapshot(columns, rows, spans, null, null, TerminalSnapshot.Cursor(cursorRow, cursorCol, cursorVisible), revision)
    }

    companion object {
        val DEFAULT_STYLE = TerminalSnapshot.Style()
    }
}
