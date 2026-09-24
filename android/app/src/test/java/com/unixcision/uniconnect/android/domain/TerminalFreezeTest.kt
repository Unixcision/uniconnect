package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Seleccionar mientras la IA escribe: el texto no se mueve hasta que se pide otra foto. */
class TerminalFreezeTest {
    private fun pantalla(texto: String) = TerminalSnapshot(
        columns = 40, rows = 1, spans = listOf(TerminalSnapshot.Span(0, 0, texto, texto.length, TerminalSnapshot.Style())),
        foreground = null, background = null, cursor = null,
    )

    @Test
    fun laFotoNoCambiaAunqueLaPantallaSiga() {
        var viva: TerminalSnapshot? = pantalla("pensando…")
        var reloj = 1_000L
        val freeze = TerminalFreeze({ viva }, { reloj })
        val primera = freeze.take()
        viva = pantalla("ya he terminado")
        reloj = 2_000L
        assertEquals("pensando…", freeze.photo?.text)
        assertEquals(1_000L, freeze.photo?.takenAt)
        assertEquals(primera, freeze.photo)
    }

    @Test
    fun actualizarSacaLoQueHayEnEseMomento() {
        var viva: TerminalSnapshot? = pantalla("antes")
        var reloj = 1_000L
        val freeze = TerminalFreeze({ viva }, { reloj })
        freeze.take()
        viva = pantalla("ahora")
        reloj = 5_000L
        val nueva = freeze.take()
        assertEquals("ahora", nueva?.text)
        assertEquals(5_000L, nueva?.takenAt)
    }

    @Test
    fun sinPantallaSeQuedaLaFotoAnterior() {
        var viva: TerminalSnapshot? = null
        val freeze = TerminalFreeze({ viva }, { 1L })
        assertNull("sin pantalla nunca hubo foto", freeze.take())
        viva = pantalla("algo")
        freeze.take()
        viva = null
        assertEquals("algo", freeze.take()?.text)
    }
}
