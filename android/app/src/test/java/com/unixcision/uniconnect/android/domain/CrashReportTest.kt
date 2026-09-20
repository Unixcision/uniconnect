package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lo que tiene que sobrevivir a que la app se cierre sola.
 *
 * Nace de un cierre real: el botón de diagnóstico leía la red sin tener el permiso declarado,
 * saltaba `SecurityException` en pleno dibujado y se llevaba la app entera. Del fallo no quedaba
 * más rastro que un «UniConnect sigue sin funcionar» que no se puede enseñar a nadie.
 */
class CrashReportTest {
    @Test
    fun `el resumen se queda con la causa raiz, no con la envoltura`() {
        val raiz = SecurityException("falta android.permission.ACCESS_NETWORK_STATE")
        val envuelto = RuntimeException("fallo al componer", IllegalStateException("intermedio", raiz))

        val report = CrashReport.of("main", "1.0 (7)", envuelto)

        assertTrue(report.summary, report.summary.contains("SecurityException"))
        assertTrue(report.summary, report.summary.contains("ACCESS_NETWORK_STATE"))
    }

    @Test
    fun `la traza completa se conserva, no solo el resumen`() {
        val report = CrashReport.of("main", "1.0 (7)", IllegalStateException("boom"))

        assertTrue(report.stack.contains("IllegalStateException"))
        assertTrue(report.render().contains("boom"))
        assertTrue(report.render().contains("main"))
    }

    @Test
    fun `una causa circular no cuelga la busqueda de la raiz`() {
        // Una excepción cuya causa es ella misma existe de verdad: algunas capas la construyen así.
        // Buscar la raíz con un bucle ingenuo se quedaría dando vueltas justo mientras el proceso
        // se muere, y entonces no se guardaría nada.
        // Java prohíbe que algo se cause a sí mismo, pero no un ciclo de dos: A causada por B y
        // B causada por A se construye sin problema, y es lo que cuelga a un recorrido ingenuo.
        val primera = RuntimeException("da vueltas")
        val segunda = RuntimeException("y vuelve", primera)
        primera.initCause(segunda)

        val report = CrashReport.of("main", "1.0 (7)", primera)

        assertEquals("main", report.thread)
        assertTrue(report.summary, report.summary.isNotBlank())
    }

    @Test
    fun `un cierre manda sobre cualquier fallo de conexion en el titular`() {
        val fallo = ConnectionEvent(
            at = 1, stage = "sondeo", machine = "MINIPC", endpoint = "100.123.234.20:8765",
            outcome = ConnectionEvent.Outcome.PLAZO_AGOTADO, millis = 20_000,
        )
        val cierre = CrashReport.of("main", "1.0 (7)", SecurityException("sin permiso"))

        val titular = DiagnosticReport.headline(listOf(fallo), listOf(cierre))

        assertTrue(titular, titular.contains("se cerró sola"))
    }

    @Test
    fun `el informe sale aunque no se haya podido leer nada del movil`() {
        val texto = DiagnosticReport.render(environment = null, events = emptyList(), now = 0L)

        assertTrue(texto.contains("no se pudo leer el entorno"))
        assertTrue(texto.contains("UniConnect"))
    }
}
