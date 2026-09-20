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
