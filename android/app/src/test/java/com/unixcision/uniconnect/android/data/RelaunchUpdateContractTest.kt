package com.unixcision.uniconnect.android.data

import com.unixcision.uniconnect.android.domain.RelaunchCause
import com.unixcision.uniconnect.android.domain.RelaunchCost
import com.unixcision.uniconnect.android.domain.RelaunchDecision
import com.unixcision.uniconnect.android.domain.RelaunchHostResult
import com.unixcision.uniconnect.android.domain.RelaunchOptions
import com.unixcision.uniconnect.android.domain.RelaunchOutcome
import com.unixcision.uniconnect.android.domain.RelaunchPresentation
import com.unixcision.uniconnect.android.domain.RelaunchScope
import com.unixcision.uniconnect.android.domain.RelaunchTargetState
import com.unixcision.uniconnect.android.domain.RelaunchUpdate
import com.unixcision.uniconnect.android.domain.RelaunchVerb
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * «Actualizar Claude» (`agent.update`), monitores, borradores y coste, por el codificador y el
 * decodificador reales contra los ejemplos del contrato (09-11-2026). Y la otra mitad: un equipo
 * anterior, que no manda nada de esto, se sigue leyendo igual y sin cifras inventadas.
 */
class RelaunchUpdateContractTest {
    private val client = NativeMachineClient(FramedRpcClient(CoroutineScope(Dispatchers.Unconfined)))

    private fun fixture(name: String): JSONObject = JSONObject(
        requireNotNull(javaClass.classLoader?.getResourceAsStream("relaunch-v1/$name"))
            { "falta el fixture del contrato: contracts/relaunch-v1/$name" }
            .bufferedReader().readText()
    )

    private fun JSONObject.keySet(): Set<String> = keys().asSequence().toSet()

    @Test fun `la peticion de actualizar es la del contrato`() {
        val acordado = fixture("plan-update-request.json")
        val scope = acordado.getJSONObject("scope")
        val options = acordado.getJSONObject("options")

        val enviado = client.planParameters(
            RelaunchVerb.UPDATE,
            RelaunchScope.Workspace("equipo", scope.getString("id")),
            RelaunchOptions(options.getString("model"), options.getString("effort")),
        )

        assertEquals(acordado.keySet(), enviado.keySet())
        assertEquals("agent.update", enviado.getString("verb"))
        assertEquals(scope.keySet(), enviado.getJSONObject("scope").keySet())
        assertEquals(scope.getString("kind"), enviado.getJSONObject("scope").getString("kind"))
        assertEquals(scope.getString("id"), enviado.getJSONObject("scope").getString("id"))
        assertEquals(options.keySet(), enviado.getJSONObject("options").keySet())
        assertEquals("fable[1m]", enviado.getJSONObject("options").getString("model"))
        assertEquals("medium", enviado.getJSONObject("options").getString("effort"))
    }

    @Test fun `igual que estaba no viaja, y solo lo que cambia va en options`() {
        val scope = RelaunchScope.Machine("equipo")
        assertFalse(client.planParameters(RelaunchVerb.UPDATE, scope, null).has("options"))
        assertFalse(client.planParameters(RelaunchVerb.UPDATE, scope, RelaunchOptions()).has("options"))
        val soloEffort = client.planParameters(RelaunchVerb.UPDATE, scope, RelaunchOptions(effort = "high")).getJSONObject("options")
        assertEquals(setOf("effort"), soloEffort.keySet())
    }

    @Test fun `relanzar sigue siendo verbo y alcance, sin options`() {
        val acordado = fixture("plan-request.json")
        val enviado = client.planParameters(
            RelaunchVerb.RELAUNCH, RelaunchScope.Workspace("equipo", acordado.getJSONObject("scope").getString("id")), null,
        )
        assertEquals(acordado.keySet(), enviado.keySet())
        assertEquals("agent.relaunch", enviado.getString("verb"))
    }

    @Test fun `relanzar con opciones no sale del movil`() {
        // El equipo contestaría opciones_no_validas: relanzar no cambia nada.
        assertThrows(IllegalArgumentException::class.java) {
            client.planParameters(RelaunchVerb.RELAUNCH, RelaunchScope.Machine("equipo"), RelaunchOptions(model = "opus[1m]"))
        }
        assertThrows(IllegalArgumentException::class.java) {
            client.planParameters(RelaunchVerb.UPDATE, RelaunchScope.Machine("equipo"), RelaunchOptions(effort = "turbo"))
        }
    }

    @Test fun `el plan de actualizar trae monitores, borrador, coste y versiones`() {
        val plan = client.decodePlan(fixture("plan-update-response.json"), RelaunchVerb.UPDATE)

        assertEquals(RelaunchVerb.UPDATE, plan.verb)
        assertEquals(RelaunchOptions("fable[1m]", "medium"), plan.options)
        assertEquals(412_000L, plan.estimatedTokens)
        assertEquals(2, plan.targets.size)

        val conMonitores = plan.targets[0]
        assertEquals(3, conMonitores.background)
        assertEquals(false, conMonitores.draft)
        assertEquals(412_000L, conMonitores.contextTokens)
        assertEquals(true, conMonitores.message)
        assertEquals("2.1.280", conMonitores.version)
        assertEquals("2.1.281", conMonitores.installed)
        assertEquals(RelaunchCause.BACKGROUND_TASKS, conMonitores.warning?.cause)

        val conBorrador = plan.targets[1]
        assertEquals(0, conBorrador.background)
        assertEquals(true, conBorrador.draft)
        assertEquals(false, conBorrador.message)
        assertNull(conBorrador.warning)

        // Las tres causas nuevas llegan con su nombre, no como «motivo no reconocido».
        assertEquals(
            listOf(RelaunchCause.PROVIDER_UNSUPPORTED, RelaunchCause.SHARED_CONVERSATION, RelaunchCause.NO_LOGIN),
            plan.exclusions.map { it.reason?.cause },
        )
    }

    @Test fun `actualizar se pregunta siempre y ensenya lo que gasta`() {
        val plan = client.decodePlan(fixture("plan-update-response.json"), RelaunchVerb.UPDATE)

        // Dos objetivos no llegan al umbral, pero actualizar nunca se ejecuta sin preguntar.
        assertTrue(RelaunchPresentation.decide(plan) is RelaunchDecision.Confirm)
        // Solo se escribe a la que tenía monitores; la del borrador se reabre sin mensaje.
        assertEquals(RelaunchCost.Rereads(messaged = 1, tokens = 412_000L, partial = false), RelaunchCost.of(listOf(plan)))
    }

    @Test fun `el resultado de actualizar dice version, monitores, mensajes y borradores`() {
        val operation = client.decodeOperation(fixture("apply-update-response.json"))

        assertTrue(operation.finished)
        assertEquals(1, operation.updates.size)
        val update = operation.updates.single()
        assertEquals("ssh:root@15.217.153.205:22", update.host)
        assertEquals(RelaunchUpdate.Kind.UPDATED, update.kind)
        assertEquals("2.1.281", update.from)
        assertEquals("2.1.321", update.to)

        val primero = operation.results[0]
        assertEquals(RelaunchTargetState.VERIFIED, primero.state)
        assertEquals("exit", primero.escalation)
        assertEquals("2.1.321", primero.version)
        assertEquals("fable[1m]", primero.model)
        assertEquals("medium", primero.effort)
        assertEquals(3, primero.backgroundSaved)
        assertEquals(true, primero.messageSent)
        assertEquals(false, primero.draftRestored)
        assertEquals(true, operation.results[1].draftRestored)
        assertEquals(false, operation.results[1].messageSent)

        val outcome = RelaunchOutcome(RelaunchVerb.UPDATE, listOf(RelaunchHostResult("m", "NOTBETTING", operation)))
        assertEquals(2, outcome.verified)
        assertEquals(2, outcome.total)
        assertEquals(3, outcome.monitorsSaved)
        assertEquals(1, outcome.messagesSent)
        assertEquals(1, outcome.draftsRestored)
        assertEquals(listOf("fable[1m] · medium"), outcome.reportedModels)
        assertTrue(outcome.problems.isEmpty())
    }

    @Test fun `un equipo anterior se lee igual y sin cifras inventadas`() {
        val plan = client.decodePlan(fixture("plan-response.json"), RelaunchVerb.RELAUNCH)

        assertTrue(plan.options.isEmpty)
        assertNull(plan.estimatedTokens)
        for (target in plan.targets) {
            assertNull(target.background)
            assertNull(target.draft)
            assertNull(target.contextTokens)
            assertNull(target.message)
            assertNull(target.version)
        }
        // Sin `message` ni `estimated_tokens` no se dice ni «gasta» ni «no gasta».
        assertEquals(RelaunchCost.Unknown, RelaunchCost.of(listOf(plan)))
        // Y el relanzado de siempre sigue ejecutándose directo con pocos objetivos.
        assertTrue(RelaunchPresentation.decide(plan) is RelaunchDecision.Apply)

        val operation = client.decodeOperation(fixture("apply-response.json"))
        assertTrue(operation.updates.isEmpty())
        assertEquals(listOf("exit", "kill_process", "respawn_pane"), operation.results.map { it.escalation })
        assertEquals(listOf("--experimental-foo"), operation.results[2].droppedOptions)
        assertNull(operation.results[0].backgroundSaved)
        assertNull(operation.results[0].messageSent)
        assertNull(operation.results[0].draftRestored)
    }

    @Test fun `un null del contrato no es un cero ni un no`() {
        val result = fixture("plan-update-response.json").apply {
            put("estimated_tokens", JSONObject.NULL)
            getJSONArray("targets").getJSONObject(0).apply {
                put("background", JSONObject.NULL)
                put("message", JSONObject.NULL)
                put("context_tokens", JSONObject.NULL)
                put("version", JSONObject.NULL)
            }
        }

        val plan = client.decodePlan(result, RelaunchVerb.UPDATE)

        assertNull(plan.estimatedTokens)
        assertNull(plan.targets[0].background)
        assertNull(plan.targets[0].message)
        assertNull(plan.targets[0].contextTokens)
        assertNull(plan.targets[0].version)
    }

    @Test fun `una actualizacion fallida o desconocida no se lee como hecha`() {
        val result = fixture("apply-update-response.json").apply {
            getJSONArray("updates").apply {
                put(JSONObject().put("host", "local:MINIPC").put("state", "fallida").put("from", "2.1.300"))
                put(JSONObject().put("host", "ssh:root@xunis:22").put("state", "ya_al_dia").put("from", "2.1.321").put("to", "2.1.321"))
                put(JSONObject().put("host", "ssh:root@prepro:22").put("state", "algo_del_futuro"))
            }
        }

        val kinds = client.decodeOperation(result).updates.map { it.kind }

        assertEquals(
            listOf(RelaunchUpdate.Kind.UPDATED, RelaunchUpdate.Kind.FAILED, RelaunchUpdate.Kind.UP_TO_DATE, RelaunchUpdate.Kind.UNKNOWN),
            kinds,
        )
    }
}
