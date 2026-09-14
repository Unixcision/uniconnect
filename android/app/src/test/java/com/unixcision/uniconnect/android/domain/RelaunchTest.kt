package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class RelaunchTest {
    private fun result(state: RelaunchTargetState, cause: RelaunchCause? = null) =
        RelaunchResult("clave-${state.wire}", state, cause)

    @Test fun `recuperada no significa terminada`() {
        // Confundirlos pone un tic verde al lado de un agente que todavía se está cerrando.
        val media = RelaunchOperation("op", recovered = true, results = listOf(
            result(RelaunchTargetState.VERIFIED), result(RelaunchTargetState.REOPENING),
        ))
        assertTrue(media.recovered)
        assertFalse(media.finished)
    }

    @Test fun `termina cuando ningun objetivo tiene fases por delante`() {
        val fin = RelaunchOperation("op", recovered = false, results = listOf(
            result(RelaunchTargetState.VERIFIED),
            result(RelaunchTargetState.NEEDS_USER, RelaunchCause.FOLDER_TRUST),
            result(RelaunchTargetState.FAILED, RelaunchCause.HOST_UNREACHABLE),
        ))
        assertTrue(fin.finished)
        assertEquals(1, fin.needingUser.size)
        // Reintentar solo lo fallido: lo que espera a una persona no se arregla solo, y lo
        // verificado no se vuelve a tocar.
        assertEquals(listOf(RelaunchTargetState.FAILED), fin.retryable.map { it.state })
    }

    @Test fun `un estado o una causa que esta version no conoce no se inventa`() {
        // Un equipo mas nuevo puede mandar algo que esta app no sabe nombrar. Se trata como fallo
        // visible en vez de como exito silencioso.
        assertEquals(RelaunchTargetState.FAILED, RelaunchTargetState.named("algo_del_futuro"))
        assertEquals(null, RelaunchCause.named("motivo_desconocido"))
        assertEquals(RelaunchTargetState.VERIFIED, RelaunchTargetState.named("verificado"))
    }

    @Test fun `se pregunta por numero de objetivos, no por el boton que se pulso`() {
        // Un espacio con una sola ventana no merece una pregunta; una maquina con veinte si, aunque
        // el boton sea el mismo.
        assertFalse(RelaunchConfirmation.needsConfirmation(1))
        assertFalse(RelaunchConfirmation.needsConfirmation(4))
        assertTrue(RelaunchConfirmation.needsConfirmation(5))
        assertTrue(RelaunchConfirmation.needsConfirmation(26))
    }
}
