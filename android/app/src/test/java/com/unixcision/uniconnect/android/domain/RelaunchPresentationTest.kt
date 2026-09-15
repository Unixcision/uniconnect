package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lo que impide que un plan que no se puede ejecutar se ejecute igualmente.
 *
 * Un plan con cero objetivos pasaba por `needsConfirmation(0)` —umbral 5, así que `false`— y se iba
 * directo a `apply`. La pantalla que explica por qué no se puede relanzar no llegaba a verse nunca,
 * y la operación vacía acababa como «Relanzadas 0 de 0».
 */
class RelaunchPresentationTest {
    private fun objetivo(n: Int) = RelaunchTarget("k$n", "CAJA · ventana $n", "claude")

    private fun plan(
        targets: List<RelaunchTarget> = emptyList(),
        exclusions: List<RelaunchExclusion> = emptyList(),
        unavailableReason: String? = null,
    ) = RelaunchPlan(
        operationID = "op",
        token = "op",
        verb = RelaunchVerb.RELAUNCH,
        targets = targets,
        exclusions = exclusions,
        unavailableReason = unavailableReason,
    )

    @Test
    fun `un plan bloqueado se ensenya, no se ejecuta`() {
        val decision = RelaunchPresentation.decide(
            plan(unavailableReason = "Falta la exclusión compartida.")
        )

        assertTrue(decision is RelaunchDecision.Show)
    }

    @Test
    fun `un plan bloqueado con objetivos tampoco se ejecuta`() {
        // El equipo puede mandar objetivos y aun así decir que no puede cerrarlos.
        val decision = RelaunchPresentation.decide(
            plan(targets = listOf(objetivo(1)), unavailableReason = "Falta acreditar la identidad.")
        )

        assertTrue(decision is RelaunchDecision.Show)
    }

    @Test
    fun `solo exclusiones y sin motivo global se ensenya igual`() {
        // Es lo que manda hoy el equipo Linux: excluye sus candidatos uno a uno y no da motivo
        // global. Tratarlo como «no había nada» escondería las causas.
        val decision = RelaunchPresentation.decide(
            plan(exclusions = listOf(RelaunchExclusion("CAJA · ventana", RelaunchReason.of("no_soportado"))))
        )

        assertTrue(decision is RelaunchDecision.Show)
    }

    @Test
    fun `sin objetivos, sin exclusiones y sin motivo si es no haber nada`() {
        assertEquals(RelaunchDecision.Nothing, RelaunchPresentation.decide(plan()))
    }

    @Test
    fun `pocos objetivos se aplican sin preguntar`() {
        val decision = RelaunchPresentation.decide(plan(targets = listOf(objetivo(1))))

        assertTrue(decision is RelaunchDecision.Apply)
    }

    @Test
    fun `muchos objetivos se preguntan`() {
        val decision = RelaunchPresentation.decide(plan(targets = (1..9).map { objetivo(it) }))

        assertTrue(decision is RelaunchDecision.Confirm)
    }

    @Test
    fun `nunca se aplica un plan sin objetivos`() {
        // La regla de fondo: da igual el motivo, si no hay a quién relanzar no se llama a apply.
        val vacios = listOf(
            plan(),
            plan(unavailableReason = "lo que sea"),
            plan(exclusions = listOf(RelaunchExclusion("x", null))),
            plan(exclusions = listOf(RelaunchExclusion("x", null)), unavailableReason = "y"),
        )

        assertTrue(vacios.none { RelaunchPresentation.decide(it) is RelaunchDecision.Apply })
    }
}
