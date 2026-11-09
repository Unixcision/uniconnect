package com.unixcision.uniconnect.android.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Lo que se enseña de coste antes de confirmar (09-11-2026): reabrir no gasta, escribirles sí.
 * Una cifra que se redondea mal o que se inventa es peor que no darla.
 */
class RelaunchCostTest {
    private fun target(n: Int, message: Boolean?, context: Long?) =
        RelaunchTarget("k$n", "CAJA · ventana $n", "claude", message = message, contextTokens = context)

    private fun plan(targets: List<RelaunchTarget>, estimated: Long? = null, unavailable: String? = null, verb: RelaunchVerb = RelaunchVerb.RELAUNCH) =
        RelaunchPlan("op", "token", verb, targets, emptyList(), unavailableReason = unavailable, estimatedTokens = estimated)

    @Test fun `los tokens se leen en miles enteros o millones con un decimal y coma`() {
        assertEquals(TokenAmount("0", TokenAmount.Scale.UNITS), TokenAmount.of(0))
        assertEquals(TokenAmount("999", TokenAmount.Scale.UNITS), TokenAmount.of(999))
        assertEquals(TokenAmount("1", TokenAmount.Scale.THOUSANDS), TokenAmount.of(1_000))
        assertEquals(TokenAmount("412", TokenAmount.Scale.THOUSANDS), TokenAmount.of(412_000))
        assertEquals(TokenAmount("413", TokenAmount.Scale.THOUSANDS), TokenAmount.of(412_500))
        // Lo que redondea a mil miles ya es un millón: «1000 mil» no se escribe.
        assertEquals(TokenAmount("1", TokenAmount.Scale.MILLIONS), TokenAmount.of(999_600))
        assertEquals(TokenAmount("1,2", TokenAmount.Scale.MILLIONS), TokenAmount.of(1_200_000))
        assertEquals(TokenAmount("1,2", TokenAmount.Scale.MILLIONS), TokenAmount.of(1_249_999))
        assertEquals(TokenAmount("1,3", TokenAmount.Scale.MILLIONS), TokenAmount.of(1_250_000))
        assertEquals(TokenAmount("2", TokenAmount.Scale.MILLIONS), TokenAmount.of(2_000_000))
        assertThrows(IllegalArgumentException::class.java) { TokenAmount.of(-1) }
    }

    @Test fun `sin escribir a ninguna no gasta`() {
        val sinMensajes = plan(listOf(target(1, message = false, context = 380_000)), estimated = 0)
        assertEquals(RelaunchCost.Free, RelaunchCost.of(listOf(sinMensajes)))
    }

    @Test fun `se suman las que reciben mensaje`() {
        val p = plan(listOf(target(1, true, 700_000), target(2, true, 500_000), target(3, false, 900_000)), estimated = 1_200_000)
        assertEquals(RelaunchCost.Rereads(2, 1_200_000, partial = false), RelaunchCost.of(listOf(p)))
    }

    @Test fun `sin estimated_tokens se suman los context_tokens de las que reciben mensaje`() {
        val p = plan(listOf(target(1, true, 700_000), target(2, false, 500_000)))
        assertEquals(RelaunchCost.Rereads(1, 700_000, partial = false), RelaunchCost.of(listOf(p)))
    }

    @Test fun `si a alguna le falta su cifra es un minimo, y sin ninguna no se sabe`() {
        val parcial = plan(listOf(target(1, true, 300_000), target(2, true, null)), estimated = 300_000)
        assertEquals(RelaunchCost.Rereads(2, 300_000, partial = true), RelaunchCost.of(listOf(parcial)))
        val ninguna = plan(listOf(target(1, true, null)), estimated = 0)
        assertEquals(RelaunchCost.Rereads(1, null, partial = true), RelaunchCost.of(listOf(ninguna)))
    }

    @Test fun `un equipo que no lo dice no se cuenta como gratis`() {
        val nuevo = plan(listOf(target(1, false, 10_000)), estimated = 0)
        val antiguo = plan(listOf(target(2, null, null)))
        assertEquals(RelaunchCost.Unknown, RelaunchCost.of(listOf(antiguo)))
        // Uno dice «no gasta», el otro calla: decir «no gasta» del total sería inventarlo.
        assertEquals(RelaunchCost.Unknown, RelaunchCost.of(listOf(nuevo, antiguo)))
        val otroNuevo = plan(listOf(target(3, true, 200_000)), estimated = 200_000)
        assertEquals(RelaunchCost.Rereads(1, 200_000, partial = true), RelaunchCost.of(listOf(otroNuevo, antiguo)))
    }

    @Test fun `un plan que no se va a ejecutar no gasta nada`() {
        val bloqueado = plan(listOf(target(1, true, 900_000)), estimated = 900_000, unavailable = "Falta la identidad.")
        assertEquals(RelaunchCost.Unknown, RelaunchCost.of(listOf(bloqueado)))
    }

    @Test fun `una ventana sola se pregunta si va a escribirle`() {
        // Antes iba directa. Escribirle es lo que gasta, y el coste se enseña antes de gastarlo.
        val conMensaje = plan(listOf(target(1, true, 412_000)), estimated = 412_000)
        assertTrue(RelaunchPresentation.decide(conMensaje) is RelaunchDecision.Confirm)
        val sinMensaje = plan(listOf(target(1, false, 412_000)), estimated = 0)
        assertTrue(RelaunchPresentation.decide(sinMensaje) is RelaunchDecision.Apply)
        val actualizar = plan(listOf(target(1, false, 412_000)), estimated = 0, verb = RelaunchVerb.UPDATE)
        assertTrue(RelaunchPresentation.decide(actualizar) is RelaunchDecision.Confirm)
    }
}
