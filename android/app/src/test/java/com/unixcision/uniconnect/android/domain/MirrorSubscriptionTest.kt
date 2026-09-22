package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Lo que impide que la app se tire la conexión a sí misma.
 *
 * Con el terminal real adjuntado la pantalla ya llega por su propio canal. Pedir además el espejo
 * llenaba la cola de eventos —que nadie vaciaba, porque esa pantalla no se estaba mirando— y el
 * transporte moría con `EventBufferOverflow` cada pocos segundos. En un informe real: 160 fallos
 * de 200 intentos, idénticos por wifi y por datos.
 */
class MirrorSubscriptionTest {
    @Test
    fun `con el terminal real adjuntado no se pide el espejo`() {
        assertNull(MirrorSubscription.target("ws-1", "win-1", realTerminalActive = true))
    }

    @Test
    fun `sin terminal real se sigue el espejo de la ventana abierta`() {
        assertEquals(
            TerminalTarget("ws-1", "win-1"),
            MirrorSubscription.target("ws-1", "win-1", realTerminalActive = false),
        )
    }

    @Test
    fun `en la lista de equipos solo se sigue el arbol`() {
        assertNull(MirrorSubscription.target(null, null, realTerminalActive = false))
        assertNull(MirrorSubscription.target("ws-1", null, realTerminalActive = false))
        assertNull(MirrorSubscription.target(null, "win-1", realTerminalActive = false))
    }
}
