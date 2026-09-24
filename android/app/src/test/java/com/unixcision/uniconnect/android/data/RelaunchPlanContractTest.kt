package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.RelaunchCause
import com.unixcision.uniconnect.android.domain.RelaunchDecision
import com.unixcision.uniconnect.android.domain.RelaunchPresentation
import com.unixcision.uniconnect.android.domain.RelaunchVerb
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * El recorrido entero: JSON del contrato -> decodificador -> decisión de presentación.
 *
 * Probar `decide` con un `RelaunchPlan` construido a mano comprueba la política y se salta las dos
 * capas donde se perdía la información: el decodificador, que tiraba la causa cruda, y el paso del
 * plan a la decisión, que mandaba a `apply` un plan sin objetivos. Estos casos entran por donde
 * entra una respuesta de verdad.
 */
class RelaunchPlanContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))

    private fun fixture(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("relaunch-v1/$name"))
            { "falta el fixture del contrato: contracts/relaunch-v1/$name" }
            .bufferedReader().readText()
    )

    @Test fun `un plan con todo excluido y sin motivo global se ensenya con sus ventanas`() {
        // Es lo que manda hoy el equipo Linux: excluye sus candidatos uno a uno.
        val plan = client.decodePlan(fixture("plan-all-excluded-response.json"), RelaunchVerb.RELAUNCH)

        assertTrue(plan.targets.isEmpty())
        assertEquals(3, plan.exclusions.size)
        assertEquals(null, plan.unavailableReason)
        assertFalse(plan.actionable)

        // Etiqueta y causa, las dos, que es lo que hace falta para saber qué le pasa a qué ventana.
        assertEquals("NOTBETTING · Notifications", plan.exclusions[0].label)
        assertEquals("no_soportado", plan.exclusions[0].reason?.wire)
        // `sin_ia` ya es una causa del contrato (24-09-2026): cambiado a propósito de «no se
        // interpreta» a su caso. El identificador crudo sigue llegando entero.
        assertEquals("sin_ia", plan.exclusions[2].reason?.wire)
        assertEquals(RelaunchCause.NO_AGENT, plan.exclusions[2].reason?.cause)

        assertTrue(RelaunchPresentation.decide(plan) is RelaunchDecision.Show)
    }

    @Test fun `un plan bloqueado por el equipo llega con su motivo y no se aplica`() {
        val plan = client.decodePlan(fixture("plan-blocked-response.json"), RelaunchVerb.RELAUNCH)

        assertTrue(plan.targets.isEmpty())
        assertTrue(plan.unavailableReason!!.contains("opciones de arranque"))
        assertFalse(plan.actionable)
        assertTrue(RelaunchPresentation.decide(plan) is RelaunchDecision.Show)
    }

    @Test fun `un plan normal del contrato si se ejecuta`() {
        // La contraprueba: si esto no llegara a ejecutarse, las de arriba no demostrarían nada.
        val plan = client.decodePlan(fixture("plan-response.json"), RelaunchVerb.RELAUNCH)

        assertEquals(2, plan.targets.size)
        assertTrue(plan.actionable)
        // `!is Show` era demasiado débil: `Nothing` también lo cumple, y entonces la prueba pasaría
        // con un plan que tampoco se ejecuta. Se exige el caso exacto.
        assertTrue(RelaunchPresentation.decide(plan) is RelaunchDecision.Apply)
    }

    @Test fun `las causas del plan normal tambien conservan su identificador`() {
        val plan = client.decodePlan(fixture("plan-response.json"), RelaunchVerb.RELAUNCH)

        assertEquals(
            listOf("identidad_ambigua", "sin_autoridad"),
            plan.exclusions.map { it.reason?.wire },
        )
    }
}
