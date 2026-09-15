package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
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
    ) = RelaunchResult(key = key, state = state, reason = cause?.let { RelaunchReason(it.wire) })

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
        assertEquals(listOf(RelaunchCause.UNSUPPORTED), RelaunchReasons.distinctReasons(intactos).map { it.cause })
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
            RelaunchReasons.distinctReasons(repetidos).map { it.cause },
        )
    }

    @Test
    fun `un resultado sin causa no inventa ninguna`() {
        val sinCausa = listOf(resultado("a", RelaunchTargetState.SKIPPED))

        assertTrue(RelaunchReasons.distinctReasons(sinCausa).isEmpty())
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
            RelaunchReasons.distinctReasons(mezcla).map { it.cause },
        )
    }

    @Test
    fun `una causa que esta version no conoce conserva su identificador`() {
        // Esta prueba antes afirmaba `named("sin_ia") == null`, que es justo lo CONTRARIO de lo
        // que su nombre promete: se quedaba verde mientras el diagnóstico se perdía.
        val futura = RelaunchReason.of("sin_ia")

        assertEquals("sin_ia", futura?.wire)
        assertEquals(null, futura?.cause)

        val resultados = listOf(resultado("a", RelaunchTargetState.SKIPPED).copy(reason = futura))
        assertEquals(listOf("sin_ia"), RelaunchReasons.distinctReasons(resultados).map { it.wire })
    }

    @Test
    fun `dos causas nuevas distintas no se funden en una`() {
        val resultados = listOf(
            resultado("a", RelaunchTargetState.SKIPPED).copy(reason = RelaunchReason.of("sin_ia")),
            resultado("b", RelaunchTargetState.SKIPPED).copy(reason = RelaunchReason.of("otra_futura")),
        )

        // Con el enum nulo las dos se habrían filtrado juntas y la pantalla no diría nada.
        assertEquals(
            listOf("sin_ia", "otra_futura"),
            RelaunchReasons.distinctReasons(resultados).map { it.wire },
        )
    }

    @Test
    fun `una causa conocida sigue interpretandose`() {
        val conocida = RelaunchReason.of("no_soportado")

        assertEquals(RelaunchCause.UNSUPPORTED, conocida?.cause)
        assertEquals("no_soportado", conocida?.wire)
    }

    private fun plan(
        targets: List<RelaunchTarget>,
        unavailableReason: String? = null,
    ) = RelaunchPlan(
        operationID = "op",
        token = "op",
        verb = RelaunchVerb.RELAUNCH,
        targets = targets,
        exclusions = emptyList(),
        unavailableReason = unavailableReason,
    )

    @Test
    fun `un plan con motivo de indisponibilidad no se ejecuta`() {
        val indisponible = plan(
            targets = listOf(RelaunchTarget("k", "CAJA · ventana", "claude")),
            unavailableReason = "Falta la exclusión compartida.",
        )

        // Aunque llegaran objetivos, el equipo ya ha dicho que no va a cerrar nada.
        assertFalse(indisponible.actionable)
    }

    @Test
    fun `un plan sin objetivos tampoco`() {
        assertFalse(plan(targets = emptyList()).actionable)
    }

    @Test
    fun `un plan con objetivos y sin motivo si`() {
        assertTrue(plan(targets = listOf(RelaunchTarget("k", "CAJA · ventana", "claude"))).actionable)
    }
}
