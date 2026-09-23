package com.unixcision.uniconnect.android.domain.vt

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.util.Base64

/**
 * Lo copiado en tmux tiene que llegar al portapapeles del móvil.
 *
 * tmux entrega lo que se selecciona en modo copia como OSC 52: `ESC ] 52 ; c ; <base64> BEL`.
 * Antes el emulador solo entendía títulos y cortaba cualquier OSC a 4096 caracteres, así que lo
 * copiado se perdía en silencio y desde el móvil no había forma de copiar nada.
 */
class OscClipboardTest {
    private fun osc52(text: String, terminator: String = "\u0007") =
        "\u001B]52;c;" + Base64.getEncoder().encodeToString(text.toByteArray(Charsets.UTF_8)) + terminator

    @Test
    fun `lo que tmux copia llega entero`() {
        val emulator = TerminalEmulator(80, 24)
        emulator.feed(osc52("git push origin uniconnect"))
        assertEquals("git push origin uniconnect", emulator.drainClipboard())
        assertNull("se entrega una vez", emulator.drainClipboard())
    }

    @Test
    fun `acentos y emojis sobreviven al base64`() {
        val emulator = TerminalEmulator(80, 24)
        emulator.feed(osc52("Reclamación nº 750641 · 459,90 € ✅"))
        assertEquals("Reclamación nº 750641 · 459,90 € ✅", emulator.drainClipboard())
    }

    @Test
    fun `vale tambien el terminador ST, no solo BEL`() {
        val emulator = TerminalEmulator(80, 24)
        emulator.feed(osc52("con ST", terminator = "\u001B\\"))
        assertEquals("con ST", emulator.drainClipboard())
    }

    @Test
    fun `un bloque grande no se corta a 4096 como los titulos`() {
        val emulator = TerminalEmulator(80, 24)
        val grande = (1..400).joinToString("\n") { "línea $it de un log que alguien quiere pegar en otro sitio" }
        emulator.feed(osc52(grande))
        assertEquals(grande, emulator.drainClipboard())
    }

    @Test
    fun `lo que llega troceado en varias lecturas se junta`() {
        val emulator = TerminalEmulator(80, 24)
        val secuencia = osc52("llegó en tres trozos")
        emulator.feed(secuencia.substring(0, 7))
        emulator.feed(secuencia.substring(7, 20))
        emulator.feed(secuencia.substring(20))
        assertEquals("llegó en tres trozos", emulator.drainClipboard())
    }

    @Test
    fun `una peticion de LEER el portapapeles no se contesta`() {
        val emulator = TerminalEmulator(80, 24)
        emulator.feed("\u001B]52;c;?\u0007")
        assertNull(emulator.drainClipboard())
        assertEquals("nada vuelve al programa remoto", "", emulator.drainResponses())
    }

    @Test
    fun `un payload que no cabe se descarta entero, no a medias`() {
        val emulator = TerminalEmulator(80, 24)
        val demasiado = "\u001B]52;c;" + "A".repeat(VtParser.MAX_CLIPBOARD_OSC + 10) + "\u0007"
        emulator.feed(demasiado)
        assertNull(emulator.drainClipboard())
        emulator.feed(osc52("el siguiente sí"))
        assertEquals("tras descartar uno, el parser sigue sano", "el siguiente sí", emulator.drainClipboard())
    }

    @Test
    fun `el OSC 52 no ensucia la pantalla ni el titulo`() {
        val emulator = TerminalEmulator(20, 2)
        emulator.feed("hola" + osc52("secreto") + " mundo")
        val texto = emulator.snapshot().spans.joinToString("") { it.text }
        assertEquals("hola mundo", texto.trim())
        assertEquals("", emulator.title)
    }

    @Test
    fun `los titulos siguen funcionando`() {
        val emulator = TerminalEmulator(20, 2)
        emulator.feed("\u001B]2;APP 2\u0007")
        assertEquals("APP 2", emulator.title)
    }
}
