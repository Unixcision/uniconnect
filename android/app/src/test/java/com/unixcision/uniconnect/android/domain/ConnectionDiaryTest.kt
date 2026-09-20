package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lo que permite dejar de adivinar por qué falló una conexión.
 *
 * Durante días se diagnosticaron fallos de conexión sin datos: la persona que lo sufría era la
 * única que estaba delante, y no tenía forma de contar qué había pasado.
 */
class ConnectionDiaryTest {
    private fun evento(
        at: Long,
        outcome: ConnectionEvent.Outcome,
        stage: String = "sondeo",
        detail: String? = null,
    ) = ConnectionEvent(
        at = at, stage = stage, machine = "MacBook de Daniel",
        endpoint = "100.120.128.58:8855", outcome = outcome, millis = 20_000, detail = detail,
    )

    @Test fun `el diario no crece sin fin`() {
        val diario = ConnectionDiary(capacity = 10)
        repeat(50) { diario.record(evento(it.toLong(), ConnectionEvent.Outcome.OK)) }

        // Un registro que crece sin límite llena el móvil y nadie lo lee entero.
        assertEquals(10, diario.all().size)
        // Y lo que queda es lo último, que es lo que explica el fallo recién visto.
        assertEquals(49L, diario.all().last().at)
    }

    @Test fun `un fallo suelto no merece molestar`() {
        val diario = ConnectionDiary()
        diario.record(evento(1, ConnectionEvent.Outcome.PLAZO_AGOTADO))
        repeat(4) { diario.record(evento(it + 2L, ConnectionEvent.Outcome.OK)) }

        // Una reconexión normal produce algún fallo; ofrecer el diagnóstico por eso es ruido.
        assertFalse(diario.worthReporting())
    }

    @Test fun `varios seguidos si`() {
        val diario = ConnectionDiary()
        repeat(3) { diario.record(evento(it.toLong(), ConnectionEvent.Outcome.PLAZO_AGOTADO)) }

        assertTrue(diario.worthReporting())
    }

    @Test fun `el informe lleva lo que hace falta para no preguntar nada`() {
        val diario = ConnectionDiary()
        diario.record(evento(1_700_000_000_000, ConnectionEvent.Outcome.PLAZO_AGOTADO,
            detail = "SocketTimeoutException tras 20000 ms"))

        val texto = DiagnosticReport.render(
            DiagnosticEnvironment(
                appVersion = "0.1.0", appBuild = "42", androidRelease = "16", sdkInt = 36,
                deviceModel = "Pixel 8 Pro", network = "móvil", networkOperator = "Digi",
                backgroundRestricted = true,
            ),
            diario.all(),
        )

        for (imprescindible in listOf(
            "0.1.0", "Pixel 8 Pro", "Android 16", "móvil", "Digi",
            "plazo_agotado", "SocketTimeoutException", "100.120.128.58:8855",
        )) {
            assertTrue("falta «$imprescindible» en el informe", texto.contains(imprescindible))
        }
        // Que Android esté cortando la app en segundo plano explica fallos que no son nuestros.
        assertTrue(texto.contains("segundo plano restringido: SÍ"))
    }

    @Test fun `la duracion viaja, porque distingue causas`() {
        val diario = ConnectionDiary()
        diario.record(evento(1, ConnectionEvent.Outcome.ERROR_TRANSPORTE).copy(millis = 30))
        diario.record(evento(2, ConnectionEvent.Outcome.PLAZO_AGOTADO).copy(millis = 20_000))

        val texto = DiagnosticReport.render(
            DiagnosticEnvironment("0.1.0", "42", "16", 36, "Pixel 8 Pro", "wifi"),
            diario.all(),
        )

        // Un rechazo en 30 ms y un plazo agotado a los 20 s no tienen la misma causa.
        assertTrue(texto.contains("30"))
        assertTrue(texto.contains("20000"))
    }

    @Test fun `el resumen nombra el ultimo fallo, no el ultimo evento`() {
        val diario = ConnectionDiary()
        diario.record(evento(1, ConnectionEvent.Outcome.RECHAZADO, detail = "approval_required"))
        diario.record(evento(2, ConnectionEvent.Outcome.OK))

        assertTrue(DiagnosticReport.headline(diario.all()).contains("approval_required"))
    }

    @Test fun `sin fallos lo dice, en vez de callar`() {
        val diario = ConnectionDiary()
        diario.record(evento(1, ConnectionEvent.Outcome.OK))

        assertEquals("Sin fallos registrados", DiagnosticReport.headline(diario.all()))
    }

    @Test fun `el nombre del fichero ordena solo`() {
        val primero = DiagnosticReport.fileName(1_700_000_000_000)
        val segundo = DiagnosticReport.fileName(1_700_000_060_000)

        assertTrue(primero < segundo)
        assertTrue(segundo.endsWith(".txt"))
    }
}

/**
 * El diario tenía que sobrevivir al cierre y avisar de que había cambiado.
 *
 * Los dos fallos que esto cubre se vieron en el móvil: el informe llegaba vacío tras reiniciar la
 * app, y el botón que lo abre no se redibujaba nunca porque la pantalla preguntaba con una llamada
 * a función en vez de mirar el estado.
 */
class ConnectionDiaryPersistenceTest {
    private class MemoriaStore(var guardado: List<ConnectionEvent> = emptyList()) : ConnectionDiary.Store {
        override fun load(): List<ConnectionEvent> = guardado
        override fun save(events: List<ConnectionEvent>) { guardado = events }
    }

    private fun intento(at: Long, outcome: ConnectionEvent.Outcome) = ConnectionEvent(
        at = at, stage = "sondeo", machine = "MINIPC", endpoint = "100.123.234.20:8765",
        outcome = outcome, millis = 20_000,
    )

    @Test
    fun `lo apuntado sigue ahi cuando el diario se vuelve a abrir`() {
        val almacen = MemoriaStore()
        ConnectionDiary(store = almacen).record(intento(1, ConnectionEvent.Outcome.PLAZO_AGOTADO))

        val reabierto = ConnectionDiary(store = almacen)

        assertEquals(1, reabierto.all().size)
        assertEquals(ConnectionEvent.Outcome.PLAZO_AGOTADO, reabierto.all().single().outcome)
    }

    @Test
    fun `cada apunte cambia la revision, que es de lo que se entera la pantalla`() {
        val diario = ConnectionDiary()
        val antes = diario.changes.value

        diario.record(intento(1, ConnectionEvent.Outcome.RECHAZADO))
        diario.record(intento(2, ConnectionEvent.Outcome.RECHAZADO))

        assertEquals(antes + 2, diario.changes.value)
    }

    @Test
    fun `un diario reabierto no supera su tamano maximo`() {
        val almacen = MemoriaStore((1L..10L).map { intento(it, ConnectionEvent.Outcome.OK) })

        val reabierto = ConnectionDiary(capacity = 3, store = almacen)

        assertEquals(3, reabierto.all().size)
        assertEquals(10L, reabierto.all().last().at)
    }
}
