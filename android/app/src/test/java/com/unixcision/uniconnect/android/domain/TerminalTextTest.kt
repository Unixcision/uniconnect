package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Test

/** Copiar desde el móvil empieza por poder leer la pantalla como texto, en su sitio. */
class TerminalTextTest {
    private val estilo = TerminalSnapshot.Style()
    private fun span(row: Int, column: Int, text: String) = TerminalSnapshot.Span(row, column, text, text.length, estilo)

    @Test
    fun `cada trozo cae en su columna y sobra el relleno final`() {
        val pantalla = TerminalSnapshot(
            columns = 20, rows = 3,
            spans = listOf(span(0, 0, "❯ git"), span(0, 6, "status"), span(1, 2, "ok   ")),
            foreground = null, background = null, cursor = null,
        )
        assertEquals("❯ git status\n  ok", TerminalText.of(pantalla))
    }

    @Test
    fun `el historial va delante de la pantalla`() {
        val pantalla = TerminalSnapshot(
            columns = 20, rows = 1, spans = listOf(span(0, 0, "ahora")),
            foreground = null, background = null, cursor = null,
            scrollbackRows = 2, scrollbackSpans = listOf(span(0, 0, "antes 1"), span(1, 0, "antes 2")),
        )
        assertEquals("antes 1\nantes 2\nahora", TerminalText.of(pantalla))
    }

    @Test
    fun `el texto invisible no se copia`() {
        val oculto = TerminalSnapshot.Span(0, 0, "clave", 5, TerminalSnapshot.Style(invisible = true))
        val pantalla = TerminalSnapshot(10, 1, listOf(oculto), null, null, null)
        assertEquals("", TerminalText.of(pantalla))
    }
}
