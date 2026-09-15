package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lo que impide que el móvil enseñe «Relanzadas 0 de N» y nada más.
 *
 * El 15-09-2026 el equipo cerró una IA viva e informó de que se había «quedado como estaba». El
 * mismo silencio llegaba al móvil por otro camino: una operación entera omitida no tenía dónde
 * aparecer, porque el diálogo solo miraba verificados, pendientes y fallidos.
 */
class RelaunchReasonsTest {
    private fun resultado(
        key: String,
        state: RelaunchTargetState,
        cause: RelaunchCause? = null,
    ) = RelaunchResult(key = key, state = state, cause = cause)

    private fun operacion(vararg results: RelaunchResult) =
        RelaunchOperation(operationID = "op", recovered = false, results = results.toList())

    @Test
    fun `una operacion entera omitida tiene algo que ensenyar`() {
        val operacion = operacion(
            resultado("a", RelaunchTargetState.SKIPPED, RelaunchCause.UNSUPPORTED),
            resultado("b", RelaunchTargetState.SKIPPED, RelaunchCause.UNSUPPORTED),
        )

        val intactos = RelaunchReasons.untouched(operacion)

        assertEquals(2, intactos.size)
        assertEquals(listOf(RelaunchCause.UNSUPPORTED), RelaunchReasons.distinctCauses(intactos))
    }

    @Test
    fun `omitido y fallido no se mezclan`() {
        val operacion = operacion(
            resultado("a", RelaunchTargetState.SKIPPED, RelaunchCause.UNSUPPORTED),
            resultado("b", RelaunchTargetState.FAILED, RelaunchCause.HOST_UNREACHABLE),
        )

        // En un fallo puede haber pasado algo; en una omisión no. Contarlos juntos es lo que hace
        // que un recuento mienta.
        assertEquals(listOf("a"), RelaunchReasons.untouched(operacion).map { it.key })
        assertEquals(listOf("b"), operacion.retryable.map { it.key })
    }

    @Test
    fun `el mismo motivo veinte veces se dice una`() {
        val repetidos = (1..20).map {
            resultado("v$it", RelaunchTargetState.SKIPPED, RelaunchCause.AMBIGUOUS_IDENTITY)
        }

        assertEquals(
            listOf(RelaunchCause.AMBIGUOUS_IDENTITY),
            RelaunchReasons.distinctCauses(repetidos),
        )
    }

    @Test
    fun `un resultado sin causa no inventa ninguna`() {
        val sinCausa = listOf(resultado("a", RelaunchTargetState.SKIPPED))

        assertTrue(RelaunchReasons.distinctCauses(sinCausa).isEmpty())
    }

    @Test
    fun `los motivos salen en orden estable`() {
        val mezcla = listOf(
            resultado("a", RelaunchTargetState.SKIPPED, RelaunchCause.UNSUPPORTED),
            resultado("b", RelaunchTargetState.FAILED, RelaunchCause.HOST_UNREACHABLE),
            resultado("c", RelaunchTargetState.SKIPPED, RelaunchCause.UNSUPPORTED),
        )

        // Dos lecturas de la misma operación tienen que enseñar la misma lista.
        assertEquals(
            listOf(RelaunchCause.UNSUPPORTED, RelaunchCause.HOST_UNREACHABLE),
            RelaunchReasons.distinctCauses(mezcla),
        )
    }

    @Test
    fun `una causa que esta version no conoce conserva su identificador`() {
        // El contrato puede crecer; lo que no puede es que el móvil pierda el diagnóstico.
        assertEquals(null, RelaunchCause.named("sin_ia"))
        assertEquals(RelaunchCause.UNSUPPORTED, RelaunchCause.named("no_soportado"))
    }
}
