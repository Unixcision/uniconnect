package com.unixcision.uniconnect.android.domain.vt

import com.unixcision.uniconnect.android.domain.TerminalSnapshot

/**
 * xterm control-sequence state machine feeding a [VtScreen]. Covers what tmux emits for its
 * clients: C0 controls, ESC sequences, CSI with private markers and sub-parameters (SGR
 * 38/48 in both `;` and `:` forms), OSC titles, DEC private modes, and the queries whose
 * answers a program may wait for (DSR, DA). Everything unknown is ignored, never crashes.
 */
class VtParser(private val screen: VtScreen, private val responses: StringBuilder) {
    private enum class State { GROUND, ESCAPE, ESCAPE_INTERMEDIATE, CSI, OSC, OSC_ESC, DCS, DCS_ESC, CHARSET }

    private var state = State.GROUND
    private val params = StringBuilder()
    private val intermediates = StringBuilder()
    private var privateMarker = 0
    private val osc = StringBuilder()
    private var charsetSlot = 0.toChar()
    private var g0LineDrawing = false
    private var g1LineDrawing = false
    private var shiftOut = false

    fun consume(codePoint: Int) {
        // C0 controls act in every state except inside OSC/DCS strings, as in xterm.
        if (codePoint < 0x20 && state != State.OSC && state != State.DCS && state != State.OSC_ESC && state != State.DCS_ESC) {
            if (codePoint == 0x1B) { state = State.ESCAPE; params.clear(); intermediates.clear(); privateMarker = 0; return }
            if (state == State.CSI && codePoint != 0x18 && codePoint != 0x1A) { control(codePoint); return }
            if (codePoint == 0x18 || codePoint == 0x1A) { state = State.GROUND; return }
            control(codePoint); return
        }
        when (state) {
            State.GROUND -> printable(codePoint)
            State.ESCAPE -> escape(codePoint)
            State.ESCAPE_INTERMEDIATE -> { intermediates.append(codePoint.toChar()); state = State.GROUND }
            State.CSI -> csi(codePoint)
            State.OSC -> when (codePoint) {
                0x07 -> { oscDispatch(); state = State.GROUND }
                0x1B -> state = State.OSC_ESC
                else -> if (osc.length < 4096) osc.appendCodePoint(codePoint)
            }
            State.OSC_ESC -> { if (codePoint == '\\'.code) oscDispatch(); state = if (codePoint == '\\'.code) State.GROUND else State.OSC }
            State.DCS -> if (codePoint == 0x1B) state = State.DCS_ESC else if (codePoint == 0x07) state = State.GROUND
            State.DCS_ESC -> state = if (codePoint == '\\'.code) State.GROUND else State.DCS
            State.CHARSET -> { charset(codePoint); state = State.GROUND }
        }
    }

    private fun control(codePoint: Int) {
        when (codePoint) {
            0x07 -> {}
            0x08 -> screen.backspace()
            0x09 -> screen.tab()
            0x0A, 0x0B, 0x0C -> screen.lineFeed()
            0x0D -> screen.carriageReturn()
            0x0E -> { shiftOut = true; screen.lineDrawing = g1LineDrawing }
            0x0F -> { shiftOut = false; screen.lineDrawing = g0LineDrawing }
        }
    }

    private fun printable(codePoint: Int) {
        if (codePoint in 0x7F..0x9F) return
        val text = if (screen.lineDrawing && codePoint in 0x60..0x7E) LINE_DRAWING[codePoint - 0x60].toString() else String(Character.toChars(codePoint))
        val width = CharWidth.of(codePoint)
        lastPrinted = text to width
        screen.print(text, width)
    }

    private fun escape(codePoint: Int) {
        state = State.GROUND
        when (codePoint.toChar()) {
            '[' -> { state = State.CSI; params.clear(); intermediates.clear(); privateMarker = 0 }
            ']' -> { state = State.OSC; osc.clear() }
            'P', 'X', '^', '_' -> state = State.DCS
            '(', ')', '*', '+' -> { charsetSlot = codePoint.toChar(); state = State.CHARSET }
            '7' -> screen.saveCursor()
            '8' -> screen.restoreCursor()
            'D' -> screen.lineFeed()
            'E' -> { screen.carriageReturn(); screen.lineFeed() }
            'H' -> screen.setTabStop()
            'M' -> screen.reverseIndex()
            'c' -> { screen.reset(); g0LineDrawing = false; g1LineDrawing = false; shiftOut = false }
            '=' -> screen.applicationKeypad = true
            '>' -> screen.applicationKeypad = false
            ' ', '#', '%' -> state = State.ESCAPE_INTERMEDIATE
            else -> {}
        }
    }

    private fun charset(codePoint: Int) {
        val drawing = codePoint == '0'.code
        when (charsetSlot) {
            '(' -> { g0LineDrawing = drawing; if (!shiftOut) screen.lineDrawing = drawing }
            ')' -> { g1LineDrawing = drawing; if (shiftOut) screen.lineDrawing = drawing }
        }
    }

    private fun csi(codePoint: Int) {
        when (codePoint) {
            in 0x30..0x3F -> {
                if (codePoint in 0x3C..0x3F && params.isEmpty() && intermediates.isEmpty()) privateMarker = codePoint
                else if (codePoint == ':'.code || codePoint == ';'.code || codePoint in 0x30..0x39) { if (params.length < 64) params.append(codePoint.toChar()) }
            }
            in 0x20..0x2F -> intermediates.append(codePoint.toChar())
            in 0x40..0x7E -> { state = State.GROUND; csiDispatch(codePoint.toChar()) }
            else -> state = State.GROUND
        }
    }

    private fun numbers(): List<Int> = params.split(';').map { it.substringBefore(':').toIntOrNull() ?: 0 }
    private fun arg(index: Int, default: Int): Int = numbers().getOrNull(index)?.takeIf { it > 0 } ?: default

    private fun csiDispatch(final: Char) {
        if (privateMarker == '?'.code) { privateMode(final); return }
        if (privateMarker == '>'.code) { if (final == 'c') responses.append("[>0;95;0c"); return }
        if (privateMarker != 0 || intermediates.isNotEmpty()) {
            if (intermediates.toString() == " " && final == 'q') return // DECSCUSR: cursor shape, purely visual
            return
        }
        when (final) {
            'A' -> screen.moveCursor(-arg(0, 1), 0)
            'B', 'e' -> screen.moveCursor(arg(0, 1), 0)
            'C', 'a' -> screen.moveCursor(0, arg(0, 1))
            'D' -> screen.moveCursor(0, -arg(0, 1))
            'E' -> { screen.moveCursor(arg(0, 1), 0); screen.carriageReturn() }
            'F' -> { screen.moveCursor(-arg(0, 1), 0); screen.carriageReturn() }
            'G', '`' -> screen.setColumn(arg(0, 1) - 1)
            'H', 'f' -> screen.moveTo(arg(0, 1) - 1, arg(1, 1) - 1)
            'd' -> screen.moveTo(arg(0, 1) - 1, screen.cursorCol)
            'I' -> repeat(arg(0, 1)) { screen.tab() }
            'Z' -> screen.backTab(arg(0, 1))
            'J' -> screen.eraseInDisplay(numbers().firstOrNull() ?: 0)
            'K' -> screen.eraseInLine(numbers().firstOrNull() ?: 0)
            'L' -> screen.insertLines(arg(0, 1))
            'M' -> screen.deleteLines(arg(0, 1))
            '@' -> screen.insertChars(arg(0, 1))
            'P' -> screen.deleteChars(arg(0, 1))
            'X' -> screen.eraseChars(arg(0, 1))
            'S' -> screen.scrollUp(arg(0, 1))
            'T' -> screen.scrollDown(arg(0, 1))
            'b' -> repeat(arg(0, 1)) { lastPrinted?.let { screen.print(it.first, it.second) } }
            'g' -> screen.clearTabStop(all = (numbers().firstOrNull() ?: 0) == 3)
            'h' -> if (numbers().contains(4)) screen.insertMode = true else if (numbers().contains(20)) screen.lineFeedNewLine = true
            'l' -> if (numbers().contains(4)) screen.insertMode = false else if (numbers().contains(20)) screen.lineFeedNewLine = false
            'm' -> sgr()
            'n' -> when (numbers().firstOrNull()) {
                5 -> responses.append("[0n")
                6 -> responses.append("[${screen.cursorRow + 1};${screen.cursorCol + 1}R")
            }
            'c' -> responses.append("[?62;22c")
            'r' -> screen.setScrollRegion(arg(0, 1) - 1, arg(1, screen.rows) - 1)
            's' -> screen.saveCursor()
            'u' -> screen.restoreCursor()
            't' -> {} // XTWINOPS: window manipulation is the desktop's business
            else -> {}
        }
    }

    private var lastPrinted: Pair<String, Int>? = null

    private fun privateMode(final: Char) {
        val enable = when (final) { 'h' -> true; 'l' -> false; else -> return }
        for (mode in numbers()) when (mode) {
            1 -> screen.applicationCursorKeys = enable
            6 -> { screen.originMode = enable; screen.moveTo(0, 0) }
            7 -> screen.autoWrap = enable
            12 -> {} // cursor blink
            25 -> screen.cursorVisible = enable
            47, 1047 -> screen.useAlternateScreen(enable, clear = enable)
            1048 -> if (enable) screen.saveCursor() else screen.restoreCursor()
            1049 -> { if (enable) { screen.saveCursor(); screen.useAlternateScreen(true, clear = true) } else { screen.useAlternateScreen(false, clear = false); screen.restoreCursor() } }
            1000, 1002, 1003 -> screen.mouseMode = if (enable) mode else 0
            1005 -> {}
            1006 -> screen.mouseSgr = enable
            2004 -> screen.bracketedPaste = enable
            else -> {}
        }
    }

    private fun sgr() {
        if (params.isEmpty()) { screen.style = VtScreen.DEFAULT_STYLE; return }
        // Split on ';' first; a ':' inside one item carries sub-parameters (ISO 8613-6 colours).
        val items = params.split(';')
        var style = screen.style
        var i = 0
        while (i < items.size) {
            val item = items[i]
            val sub = item.split(':')
            val code = sub[0].toIntOrNull() ?: 0
            when (code) {
                0 -> style = VtScreen.DEFAULT_STYLE
                1 -> style = style.copy(bold = true)
                2 -> style = style.copy(faint = true)
                3 -> style = style.copy(italic = true)
                4, 21 -> style = style.copy(underline = (sub.getOrNull(1)?.toIntOrNull() ?: 1) != 0)
                7 -> style = style.copy(inverse = true)
                8 -> style = style.copy(invisible = true)
                9 -> style = style.copy(strikethrough = true)
                22 -> style = style.copy(bold = false, faint = false)
                23 -> style = style.copy(italic = false)
                24 -> style = style.copy(underline = false)
                27 -> style = style.copy(inverse = false)
                28 -> style = style.copy(invisible = false)
                29 -> style = style.copy(strikethrough = false)
                in 30..37 -> style = style.copy(foreground = Palette.hex(code - 30))
                in 90..97 -> style = style.copy(foreground = Palette.hex(code - 90 + 8))
                39 -> style = style.copy(foreground = null)
                in 40..47 -> style = style.copy(background = Palette.hex(code - 40))
                in 100..107 -> style = style.copy(background = Palette.hex(code - 100 + 8))
                49 -> style = style.copy(background = null)
                53 -> style = style.copy(overline = true)
                55 -> style = style.copy(overline = false)
                38, 48, 58 -> {
                    val (color, consumed) = extendedColor(sub, items, i)
                    i += consumed
                    if (code == 38) style = style.copy(foreground = color) else if (code == 48) style = style.copy(background = color)
                }
                else -> {}
            }
            i++
        }
        screen.style = style
    }

    /** Returns the colour and how many extra `;`-items were consumed. */
    private fun extendedColor(sub: List<String>, items: List<String>, index: Int): Pair<String?, Int> {
        if (sub.size > 1) {
            val kind = sub[1].toIntOrNull()
            return when (kind) {
                5 -> Palette.hex(sub.getOrNull(2)?.toIntOrNull() ?: 0) to 0
                2 -> {
                    // 38:2:r:g:b or 38:2::r:g:b (colour-space id present)
                    val rgb = sub.drop(2).let { if (it.size >= 4) it.drop(1) else it }.map { it.toIntOrNull() ?: 0 }
                    Palette.rgb(rgb.getOrElse(0) { 0 }, rgb.getOrElse(1) { 0 }, rgb.getOrElse(2) { 0 }) to 0
                }
                else -> null to 0
            }
        }
        val kind = items.getOrNull(index + 1)?.toIntOrNull()
        return when (kind) {
            5 -> Palette.hex(items.getOrNull(index + 2)?.toIntOrNull() ?: 0) to 2
            2 -> Palette.rgb(items.getOrNull(index + 2)?.toIntOrNull() ?: 0, items.getOrNull(index + 3)?.toIntOrNull() ?: 0, items.getOrNull(index + 4)?.toIntOrNull() ?: 0) to 4
            else -> null to 0
        }
    }

    private fun oscDispatch() {
        val text = osc.toString()
        val code = text.substringBefore(';').toIntOrNull() ?: return
        val payload = text.substringAfter(';', "")
        when (code) {
            0, 2 -> screen.title = payload
            // 10/11 colour queries expect an answer; tmux forwards them and programs may wait.
            10 -> if (payload == "?") responses.append("]10;rgb:eeee/f3f3/ffff\\")
            11 -> if (payload == "?") responses.append("]11;rgb:0707/0d0d/2020\\")
            else -> {}
        }
    }

    companion object {
        private const val LINE_DRAWING = "◆▒␉␌␍␊°±␤␋┘┐┌└┼⎺⎻─⎼⎽├┤┴┬│≤≥π≠£·"
    }
}

/** xterm's default 256-colour palette as `#rrggbb`, the form [TerminalSnapshot.Style] carries. */
object Palette {
    private val base = arrayOf(
        "#000000", "#cd0000", "#00cd00", "#cdcd00", "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
        "#7f7f7f", "#ff0000", "#00ff00", "#ffff00", "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
    )
    private val steps = intArrayOf(0, 95, 135, 175, 215, 255)

    fun hex(index: Int): String = when (index.coerceIn(0, 255)) {
        in 0..15 -> base[index.coerceIn(0, 15)]
        in 16..231 -> { val i = index - 16; rgb(steps[i / 36], steps[i / 6 % 6], steps[i % 6]) }
        else -> { val v = 8 + (index - 232) * 10; rgb(v, v, v) }
    }

    fun rgb(r: Int, g: Int, b: Int): String = String.format("#%02x%02x%02x", r.coerceIn(0, 255), g.coerceIn(0, 255), b.coerceIn(0, 255))
}
