package com.unixcision.uniconnect.android.domain.vt

import com.unixcision.uniconnect.android.domain.TerminalSnapshot

/**
 * A complete client-side terminal for one attached tmux client: bytes in, snapshot out.
 *
 * Feed raw PTY output with [feed]; read the screen with [snapshot]; send whatever the
 * program asked for (cursor position, device attributes) back to the PTY from [drainResponses].
 * Key and mouse encoding consult the modes the program enabled ([applicationCursorKeys],
 * [encodeWheel]). No Android types: it is unit-tested on the JVM.
 */
class TerminalEmulator(columns: Int, rows: Int) {
    val screen = VtScreen(columns, rows)
    private val responses = StringBuilder()
    private val parser = VtParser(screen, responses)
    private val decoder = Utf8Decoder()
    private var revision = 0uL

    fun feed(bytes: ByteArray) {
        decoder.decode(bytes) { codePoint -> parser.consume(codePoint) }
        revision++
    }

    fun feed(text: String) = feed(text.toByteArray(Charsets.UTF_8))

    fun snapshot(): TerminalSnapshot = screen.snapshot(revision)

    /** Bytes the program is waiting for (DSR/DA answers); empty when nothing is pending. */
    fun drainResponses(): String = responses.toString().also { responses.setLength(0) }

    val applicationCursorKeys: Boolean get() = screen.applicationCursorKeys
    val bracketedPaste: Boolean get() = screen.bracketedPaste
    val mouseReporting: Boolean get() = screen.mouseMode != 0
    val title: String get() = screen.title

    fun resize(columns: Int, rows: Int) { screen.resize(columns, rows); revision++ }

    /**
     * Wheel step. When the inner program asked for mouse events it gets its own encoding;
     * otherwise an SGR step is still produced, because the reader may be tmux itself, whose
     * copy-mode scrolls on wheel events the program never sees.
     */
    fun encodeWheel(up: Boolean, column: Int, row: Int): String {
        val button = if (up) 64 else 65
        return if (screen.mouseSgr || screen.mouseMode == 0) "[<$button;${column + 1};${row + 1}M"
        else "[M${(32 + button).toChar()}${(32 + column + 1).coerceAtMost(255).toChar()}${(32 + row + 1).coerceAtMost(255).toChar()}"
    }

    /** Press or release of the primary button; null when mouse reporting is off. */
    fun encodeClick(pressed: Boolean, column: Int, row: Int): String? {
        if (screen.mouseMode == 0) return null
        return if (screen.mouseSgr) "[<0;${column + 1};${row + 1}${if (pressed) 'M' else 'm'}"
        else "[M${(32 + if (pressed) 0 else 3).toChar()}${(32 + column + 1).coerceAtMost(255).toChar()}${(32 + row + 1).coerceAtMost(255).toChar()}"
    }

    /** Wraps pasted text in bracketed-paste markers when the program opted in. */
    fun encodePaste(text: String): String = if (screen.bracketedPaste) "[200~$text[201~" else text
}
